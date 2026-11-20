import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1339: the Agent Sessions sidebar's state glyph (agentGlyphColor) is at least 3:1 (WCAG 1.4.11) over the sidebar and over
/// the selected row's fill (the accent at 0.14 over the sidebar) for every state colour on every bundled theme, in the
/// same hue. Computed from the theme tokens: no render, no window, no appearance read. Fakes only.
@MainActor
final class AgentGlyphContrastTests: XCTestCase {

    static let expected = ["Default", "theme-amber", "theme-blossom", "theme-contrast-dark", "theme-contrast-light",
                           "theme-crimson", "theme-daylight", "theme-default", "theme-ember", "theme-emerald",
                           "theme-fern", "theme-gold", "theme-graphite", "theme-indigo", "theme-lavender",
                           "theme-lime", "theme-mint", "theme-rose", "theme-royal", "theme-silver", "theme-solar",
                           "theme-teal"]
    static let states: [AgentState] = [.blocked, .working, .done, .idle]

    /// The registry: the built-in plus every bundled theme-* extension directory.
    func registry() throws -> [ThemeDescriptor] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let bundled = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .map { d -> ThemeDescriptor in
                let json = d.appendingPathComponent("theme.json")
                let spec = try ThemeSpec.decode(Data(contentsOf: json))
                return ThemeDescriptor(id: "test.1339.\(d.lastPathComponent)", title: d.lastPathComponent,
                                       appearance: spec.appearance, extensionID: "test.1339", jsonPath: json)
            }
        return [ThemeDescriptor.builtIn] + bundled
    }

    func rgb(_ c: Color) -> [CGFloat] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return [n.redComponent, n.greenComponent, n.blueComponent]
    }
    func hue(_ c: Color) -> CGFloat {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return n.hueComponent
    }

    func testTheLiteralListIsTheRegistry() throws {
        let all = try registry()
        XCTAssertEqual(Set(all.map(\.title)), Set(Self.expected), "a new theme must be added to the literal list")
        XCTAssertEqual(all.count, Self.expected.count)
    }

    func testEveryStateGlyphClearsThreeToOneOnEveryThemeSelectedOrNot() throws {
        _ = ThemeStore.shared
        let (savedPalette, savedIC) = (ThemeRuntime.palette, ThemeRuntime.increaseContrast)
        defer { ThemeRuntime.palette = savedPalette; ThemeRuntime.increaseContrast = savedIC }
        ThemeRuntime.increaseContrast = false
        var pairs = 0
        for title in Self.expected {
            guard let d = try registry().first(where: { $0.title == title }) else { XCTFail("\(title) is not in the registry"); continue }
            let p = ThemePalette.load(for: d)
            ThemeRuntime.palette = p
            let side = rgb(p.sidebar), tint = rgb(p.blue)
            let sel = zip(side, tint).map { $0 * 0.86 + $1 * 0.14 }
            let selected = NSColor(srgbRed: sel[0], green: sel[1], blue: sel[2], alpha: 1)
            let sidebar = NSColor(srgbRed: side[0], green: side[1], blue: side[2], alpha: 1)
            for state in Self.states {
                let glyph = NSColor(agentGlyphColor(state))
                for (name, bg) in [("sidebar", sidebar), ("selected row", selected)] {
                    let r = ThemeContrastTests.contrast(glyph, on: bg)
                    XCTAssertGreaterThanOrEqual(r, 3.0, "\(title): \(state) glyph on the \(name) is \(r):1")
                    pairs += 1
                }
                // The hue stays (amber stays amber); a theme that already clears 3:1 keeps agentStateColor exactly.
                let base = agentStateColor(state)
                if state != .idle, d.appearance == .light {
                    XCTAssertEqual(hue(agentGlyphColor(state)), hue(base), accuracy: 0.02, "\(title): \(state) keeps its hue")
                } else {
                    XCTAssertEqual(rgb(agentGlyphColor(state)), rgb(base), "\(title): \(state) is unchanged")
                }
            }
        }
        XCTAssertEqual(pairs, 22 * 4 * 2)
    }
}
