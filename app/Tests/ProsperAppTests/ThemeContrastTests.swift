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
        MainActor.assumeIsolated { ThemeStore.shared.setAvailable([]) }   // #754: XCTest tears down on main
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

    /// #753 / QA #582 INFO-1: a popover already on screen (a pinned Calendar) follows a
    /// live theme switch instead of keeping the appearance it showed with.
    func testShownPopoverFollowsALiveThemeSwitch() throws {
        let all = try themes()
        ThemeStore.shared.setAvailable(Array(all.dropFirst()))
        let light = try XCTUnwrap(all.first { $0.appearance == .light })
        let dark = try XCTUnwrap(all.dropFirst().first { $0.appearance == .dark })
        ThemeStore.shared.select(id: dark.id)
        let popover = NSPopover()
        NotificationCenter.default.post(name: NSPopover.willShowNotification, object: popover)
        XCTAssertEqual(popover.appearance?.name, .darkAqua)
        ThemeStore.shared.select(id: light.id)
        XCTAssertEqual(popover.appearance?.name, .aqua, "shown popover kept the old theme's appearance")
        ThemeStore.shared.select(id: dark.id)
        XCTAssertEqual(popover.appearance?.name, .darkAqua)
    }

    /// #753 / QA #582 INFO-4: the observer runs on main (queue .main), so a willShow
    /// posted off the main thread is applied there instead of trapping in assumeIsolated.
    func testPopoverObserverIsSafeOffTheMainThread() throws {
        let all = try themes()
        ThemeStore.shared.setAvailable(Array(all.dropFirst()))
        let light = try XCTUnwrap(all.first { $0.appearance == .light })
        ThemeStore.shared.select(id: light.id)
        let popover = NSPopover()
        popover.appearance = NSAppearance(named: .darkAqua)
        nonisolated(unsafe) let sent = popover
        let posted = expectation(description: "posted off main")
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: NSPopover.willShowNotification, object: sent)
            posted.fulfill()
        }
        wait(for: [posted], timeout: 5)
        XCTAssertEqual(popover.appearance?.name, .aqua)
    }

    /// #753: under a LIGHT theme the in-window popovers (Settings app picker, Chat
    /// history and persona) forced `.preferredColorScheme(.dark)` over the theme's
    /// appearance, so the light theme's dark text sat on dark fields and the system
    /// labels drew near-white on the light backdrop (1.00-1.26:1). Offscreen, per
    /// theme, live-switched: a themed window (no appearance of its own) and the real
    /// app-picker popover body (in a window given the theme's appearance, as the
    /// willShow observer gives the popover) must both render in the theme's
    /// appearance, and the theme's text and the system labels must clear 4.5:1.
    func testWindowsAndTheirPopoversWearTheThemeAppearance() throws {
        _ = NSApplication.shared
        let all = try themes()
        ThemeStore.shared.setAvailable(Array(all.dropFirst()))
        // The window stays open across the switches (the live path); a popover is
        // built per show, so the picker body gets a fresh window per theme.
        let settings = Self.offscreenWindow(Themed(rebuildOnSizeChangeOnly: true) { AppearanceSettingsPane() })
        defer { settings.contentViewController = nil; settings.close() }
        for d in all {
            ThemeStore.shared.select(id: d.id)
            let picker = Self.offscreenWindow(AppPickerMenu(label: "App", onPick: { _, _ in }).popoverBody,
                                              appearance: d.appearance.nsAppearanceName)
            defer { picker.contentViewController = nil; picker.close() }
            for w in [settings, picker] { Self.pump(w) }
            let p = ThemePalette.load(for: d)
            let bg = NSColor(p.bgTop), card = Self.flatten(NSColor(p.card), over: bg)
            for (surface, w) in [("window", settings), ("app picker popover", picker)] {
                let eff = try XCTUnwrap(w.contentView).effectiveAppearance
                XCTAssertEqual(eff.name, d.appearance.nsAppearanceName, "\(d.title): \(surface) is \(eff.name.rawValue)")
                func resolved(_ c: NSColor) -> NSColor {
                    var r = NSColor.clear
                    eff.performAsCurrentDrawingAppearance { r = Self.srgbColor(c) }
                    return r
                }
                for (fn, fill) in [("textBackgroundColor", NSColor.textBackgroundColor), ("controlColor", .controlColor),
                                   ("controlBackgroundColor", .controlBackgroundColor)] {
                    let r = Self.contrast(NSColor(p.textPrimary), on: Self.flatten(resolved(fill), over: bg))
                    XCTAssertGreaterThanOrEqual(r, Self.minimum, "\(d.title) \(surface): textPrimary on \(fn) is \(r):1")
                }
                for (sn, s) in [("bgTop", bg), ("card", card)] {
                    let r = Self.contrast(resolved(.labelColor), on: s)
                    XCTAssertGreaterThanOrEqual(r, Self.minimum, "\(d.title) \(surface): labelColor on \(sn) is \(r):1")
                }
            }
        }
    }

    /// #753: nothing pins a surface dark (or light) behind the theme's back; the
    /// theme's appearance reaches windows through NSApp.appearance and popovers
    /// through the willShow observer. A pin like the ones #753 removed fails here,
    /// including in views a test cannot host (the private Chat popovers).
    func testNoSurfacePinsItsOwnAppearance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        let pins = [".preferredColorScheme(.dark)", ".preferredColorScheme(.light)",
                    "NSAppearance(named: .darkAqua)", "NSAppearance(named: .aqua)"]
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for pin in pins where text.contains(pin) {
                XCTFail("\(f.lastPathComponent) pins \(pin); use the theme's appearance")
            }
        }
    }

    /// A never-ordered window far off every screen (the harness never shows it).
    private static func offscreenWindow<V: View>(_ root: V, appearance: NSAppearance.Name? = nil) -> NSWindow {
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let win = NSWindow(contentViewController: host)
        win.appearance = appearance.flatMap { NSAppearance(named: $0) }
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 640, height: 480))
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        return win
    }

    private static func pump(_ win: NSWindow) {
        guard let v = win.contentView else { return }
        for _ in 0..<3 {
            v.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            v.displayIfNeeded()
        }
    }

    private static func srgbColor(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB) ?? c }

    private static func flatten(_ c: NSColor, over bg: NSColor) -> NSColor {
        let f = srgb(c), b = srgb(bg)
        return NSColor(srgbRed: f.r * f.a + b.r * (1 - f.a), green: f.g * f.a + b.g * (1 - f.a),
                       blue: f.b * f.a + b.b * (1 - f.a), alpha: 1)
    }
}
