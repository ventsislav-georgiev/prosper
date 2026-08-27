import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #089 — the end of the #078 saga. Selecting a theme must repaint `.neonCard()`
/// chrome, not just the content it wraps.
///
/// Rounds 1-6 all assumed the palette was arriving late and answered with more
/// `.id()` teardown INSIDE the card. `testInlineNeonReadIsFreshOnSelect` shows
/// that assumption was wrong: `ThemeRuntime.palette` is already the new palette
/// by the time SwiftUI re-runs a self-observing body (ThemeStore.apply writes it
/// at Theme/ThemeStore.swift:263, before the `generation` bump at :271), so an
/// inline `Neon.*` read repaints fine with no id at all.
/// `testNeonCardRepaintsOnSelect` is the one that was broken: a `ViewModifier`
/// receives its content as an opaque `_ViewModifier_Content` placeholder, so its
/// `body` is a pure function of the MODIFIER's value — a property-less
/// `NeonCardModifier()` never compares unequal, SwiftUI keeps the memoized body,
/// and the card fill stays frozen at whatever palette was live when it first
/// rendered. No amount of identity churn on the wrapped content can reach it.
@MainActor
final class ThemeCardRepaintTests: XCTestCase {
    /// A card fill nothing else in the palette resolves to, so a stale pixel is
    /// unmistakable.
    private static let probeCardHex = "#FF00FF"

    /// Mirrors `NeonSection.card`: self-observing, generation-keyed interior,
    /// card chrome applied OUTSIDE that key.
    private struct CardProbe: View {
        @ObservedObject private var theme = ThemeStore.shared
        var body: some View {
            Color.clear
                .frame(width: 60, height: 60)
                .id("probe:\(theme.generation)")
                .padding(sz(16))
                .neonCard()
        }
    }

    /// Control: the `SettingsBackground` shape — a self-observing view reading
    /// `Neon.*` inline in its own body, no `.id()` anywhere.
    private struct InlineProbe: View {
        @ObservedObject private var theme = ThemeStore.shared
        var body: some View {
            Rectangle().fill(Neon.card).frame(width: 120, height: 120)
        }
    }

    /// `setAvailable([])` re-applies the built-in Default, which restores the
    /// global `ThemeRuntime.palette` (the apply guard compares against it, so it
    /// never short-circuits on a palette a previous test left behind).
    private func resetThemeGlobals() {
        UserDefaults.standard.removeObject(forKey: "prosper.activeThemeID")
        ThemeStore.shared.setAvailable([])
    }

    private func host<V: View>(_ view: V, side: CGFloat) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        h.frame = CGRect(x: 0, y: 0, width: side, height: side)
        flush(h)
        return h
    }

    /// Let SwiftUI's scheduled update land, then force a synchronous display.
    private func flush(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func centerColor(_ view: NSView) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let c = try XCTUnwrap(rep.colorAt(x: Int(view.bounds.midX), y: Int(view.bounds.midY)))
        return try XCTUnwrap(c.usingColorSpace(.sRGB))
    }

    /// The pixel a plain fill of `color` produces through this exact harness.
    /// Self-calibrating: the offscreen bitmap's color space is whatever AppKit
    /// picks for a windowless view, so comparing against a rendered reference
    /// beats hardcoding sRGB components (a saturated fill round-trips through
    /// the display gamut and comes back several hundredths off).
    private func reference(_ color: Color) throws -> NSColor {
        try centerColor(host(Rectangle().fill(color).frame(width: 120, height: 120), side: 120))
    }

    private func assertColor(_ c: NSColor, matches want: NSColor,
                             _ what: String, line: UInt = #line) {
        XCTAssertEqual(c.redComponent, want.redComponent, accuracy: 0.02, "\(what) red", line: line)
        XCTAssertEqual(c.greenComponent, want.greenComponent, accuracy: 0.02, "\(what) green", line: line)
        XCTAssertEqual(c.blueComponent, want.blueComponent, accuracy: 0.02, "\(what) blue", line: line)
    }

    /// Installs a light theme whose `card` is `probeCardHex` and selects it.
    private func selectProbeTheme() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "theme-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appending(path: "theme.json")
        let body = "{ \"appearance\": \"light\", \"colors\": { \"card\": \"\(Self.probeCardHex)\" } }"
        try Data(body.utf8).write(to: json)
        let d = ThemeDescriptor(id: "t.repaint", title: "Repaint", appearance: .light,
                                extensionID: "e", jsonPath: json)
        ThemeStore.shared.setAvailable([d])
        ThemeStore.shared.select(id: d.id)
        XCTAssertEqual(ThemeStore.shared.activeID, d.id, "select must have applied")
    }

    // MARK: - Control: the palette is already current when bodies re-run

    func testInlineNeonReadIsFreshOnSelect() throws {
        resetThemeGlobals()
        defer { resetThemeGlobals() }
        let stale = try reference(ThemePalette.default.card)
        let fresh = try reference(Color(hex: Self.probeCardHex)!)

        let h = host(InlineProbe(), side: 120)
        assertColor(try centerColor(h), matches: stale, "default card before select")

        try selectProbeTheme()
        flush(h)
        assertColor(try centerColor(h), matches: fresh, "inline Neon.card after select")
    }

    // MARK: - Regression: the card chrome itself must repaint

    func testNeonCardRepaintsOnSelect() throws {
        resetThemeGlobals()
        defer { resetThemeGlobals() }
        let stale = try reference(ThemePalette.default.card)
        let fresh = try reference(Color(hex: Self.probeCardHex)!)

        let h = host(CardProbe(), side: 120)
        assertColor(try centerColor(h), matches: stale, "default card before select")

        try selectProbeTheme()
        flush(h)
        assertColor(try centerColor(h), matches: fresh,
                    "neonCard() fill after select — a property-less ViewModifier memoizes its body")
    }
}
