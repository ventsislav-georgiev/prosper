import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #752: under macOS Light the default (dark) theme's near-white text sat on aqua
/// controls in the status-item popovers (Sensors, Calendar), because those popovers
/// took the menu bar's appearance instead of the theme's. Two guards, run for the
/// built-in default and every bundled theme:
/// - the theme's own text tokens clear WCAG AA (4.5:1) on every surface token;
/// - a popover about to show adopts the THEME's appearance whatever the system
///   (menu bar) appearance is, and the theme's text clears 4.5:1 on the system
///   control fills as they resolve in that appearance.
@MainActor
final class ThemeContrastTests: XCTestCase {
    private static let minimum: CGFloat = 4.5

    override func tearDown() {
        // Back to the built-in default, as ThemeCardRepaintTests does.
        Preferences.defaults.removeObject(forKey: "prosper.activeThemeID")
        ThemeStore.shared.setAvailable([])
        super.tearDown()
    }

    /// The built-in default plus one descriptor per bundled theme-* extension.
    private func themes() throws -> [ThemeDescriptor] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.752.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.752", jsonPath: json)
            }
        XCTAssertGreaterThanOrEqual(bundled.count, 21, "bundled theme set went missing")
        return [.builtIn] + bundled
    }

    private static func srgb(_ c: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let n = c.usingColorSpace(.sRGB) ?? c
        return (n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }

    private static func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG 2 contrast ratio. `fg` is composited over `bg` first when translucent.
    static func contrast(_ fg: NSColor, on bg: NSColor) -> CGFloat {
        let b = srgb(bg), f = srgb(fg)
        let over = (r: f.r * f.a + b.r * (1 - f.a), g: f.g * f.a + b.g * (1 - f.a),
                    b: f.b * f.a + b.b * (1 - f.a), a: CGFloat(1))
        let l1 = luminance(over), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testContrastMatchesWCAGReferencePoints() {
        XCTAssertEqual(Self.contrast(.black, on: .white), 21, accuracy: 0.01)
        XCTAssertEqual(Self.contrast(.white, on: .white), 1, accuracy: 0.01)
        // #767676 on white is the classic 4.54:1 AA boundary grey.
        let grey = NSColor(srgbRed: 0x76 / 255.0, green: 0x76 / 255.0, blue: 0x76 / 255.0, alpha: 1)
        XCTAssertEqual(Self.contrast(grey, on: .white), 4.54, accuracy: 0.01)
    }

    /// Text tokens on the surfaces they are painted on (window backdrop, sidebar,
    /// cards, selected rows). Token colours do not depend on the system appearance,
    /// so this holds in light and dark alike.
    func testThemeTextClearsEverySurfaceToken() throws {
        let surfaces: [(String, KeyPath<ThemePalette, Color>)] = [
            ("bgTop", \.bgTop), ("bgBottom", \.bgBottom), ("sidebar", \.sidebar),
            ("card", \.card), ("cardHi", \.cardHi),
        ]
        let texts: [(String, KeyPath<ThemePalette, Color>)] = [
            ("textPrimary", \.textPrimary), ("textSecondary", \.textSecondary),
        ]
        for d in try themes() {
            let p = ThemePalette.load(for: d)
            for (tn, t) in texts {
                for (sn, s) in surfaces {
                    let r = Self.contrast(NSColor(p[keyPath: t]), on: NSColor(p[keyPath: s]))
                    XCTAssertGreaterThanOrEqual(r, Self.minimum, "\(d.title): \(tn) on \(sn) is \(r):1")
                }
            }
        }
    }

    /// The #752 path: a popover anchored to the menu bar arrives in the SYSTEM
    /// appearance. As it shows it must switch to the theme's, so the controls inside
    /// draw their fills for the theme's text, under system Light and Dark alike.
    func testPopoverControlsTakeThemeAppearanceInEitherSystemAppearance() throws {
        let all = try themes()
        ThemeStore.shared.setAvailable(Array(all.dropFirst()))
        let fills: [(String, NSColor)] = [
            ("textBackgroundColor", .textBackgroundColor),   // TextField fill
            ("controlColor", .controlColor),                 // push button / segment fill
            ("controlBackgroundColor", .controlBackgroundColor),
        ]
        for d in all {
            ThemeStore.shared.select(id: d.id)
            XCTAssertEqual(ThemeStore.shared.activeID, d.id)
            let p = ThemePalette.load(for: d)
            let backdrop = NSColor(p.bgTop)
            for system in [NSAppearance.Name.aqua, .darkAqua] {
                let popover = NSPopover()
                popover.appearance = NSAppearance(named: system)
                NotificationCenter.default.post(name: NSPopover.willShowNotification, object: popover)
                let got = try XCTUnwrap(popover.appearance, "\(d.title) under \(system.rawValue)")
                XCTAssertEqual(got.name, d.appearance.nsAppearanceName,
                               "\(d.title) under \(system.rawValue): popover kept the menu bar's appearance")
                for (fn, fill) in fills {
                    var resolved = NSColor.clear
                    got.performAsCurrentDrawingAppearance { resolved = Self.srgbColor(fill) }
                    // A translucent fill (dark controlColor) is seen over the theme backdrop.
                    let control = Self.flatten(resolved, over: backdrop)
                    let r = Self.contrast(NSColor(p.textPrimary), on: control)
                    XCTAssertGreaterThanOrEqual(r, Self.minimum,
                        "\(d.title) under system \(system.rawValue): textPrimary on \(fn) is \(r):1")
                }
            }
        }
    }

    private static func srgbColor(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }

    private static func flatten(_ c: NSColor, over bg: NSColor) -> NSColor {
        let f = srgb(c), b = srgb(bg)
        return NSColor(srgbRed: f.r * f.a + b.r * (1 - f.a), green: f.g * f.a + b.g * (1 - f.a),
                       blue: f.b * f.a + b.b * (1 - f.a), alpha: 1)
    }
}
