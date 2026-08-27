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
///
/// #100 then reused this harness to decide which of that identity churn was
/// still doing anything — see `testStableRowIDsRepaintOnSelect`.
@MainActor
final class ThemeCardRepaintTests: XCTestCase {
    /// A card fill nothing else in the palette resolves to, so a stale pixel is
    /// unmistakable.
    private static let probeCardHex = "#FF00FF"
    /// #100: two more tokens the Settings chrome never touches (`Neon.magenta`
    /// is only ever read by `NeonButtonStyle(destructive:)`, `Neon.terminal` by
    /// nothing in SettingsTheme.swift), so a pixel of either can only have come
    /// from the probe rows / probe child below. Same theme, so one select moves
    /// all three.
    private static let probeMagentaHex = "#00FF00"
    private static let probeTerminalHex = "#FF8000"
    private static let probeCardHiHex = "#FFFF00"

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

    private func host<V: View>(_ view: V, side: CGFloat, height: CGFloat? = nil) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        h.frame = CGRect(x: 0, y: 0, width: side, height: height ?? side)
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
        let body = """
        { "appearance": "light", "colors": {
            "card": "\(Self.probeCardHex)",
            "magenta": "\(Self.probeMagentaHex)",
            "terminal": "\(Self.probeTerminalHex)",
            "cardHi": "\(Self.probeCardHiHex)" } }
        """
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

    // MARK: - #100: the real pane composition, with no generation folded anywhere

    /// Mirrors `AppearanceSettingsPane`'s theme list as closely as a test can:
    /// `NeonScroll`'s `LazyVStack` → a titled `NeonSection` (so the section's
    /// own `.id(anchor)` really is at the lazy child boundary) → the caller's
    /// content closure → one explicit `.id()` per row. The rows are written
    /// inline in this self-observing container's own body, exactly like
    /// `AppearanceSettingsPane.row`, and the "Theme" section is the SECOND lazy
    /// child, as it is on screen.
    private struct ThemeListProbe: View {
        /// Load-bearing even though nothing reads it: it is what re-runs this
        /// body on a select, exactly as `AppearanceSettingsPane`'s own
        /// `@ObservedObject` does.
        @ObservedObject private var theme = ThemeStore.shared

        static let rowIDs = ["t.one", "t.two", "t.three"]

        var body: some View {
            NeonScroll {
                NeonSection("Menu Bar Icon") {
                    Text("swatches").font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                }
                NeonSection("Theme", footer: "↑/↓ moves the selection.") {
                    VStack(alignment: .leading, spacing: sz(14)) {
                        ForEach(Array(Self.rowIDs.enumerated()), id: \.element) { idx, id in
                            if idx > 0 { NeonDivider() }
                            // The production anchor itself, not a copy — so this
                            // measures whatever identity scheme the pane ships.
                            row(id).id(AppearanceSettingsPane.rowAnchor(pane: "appearance", themeID: id))
                        }
                    }
                    DetachedChild()
                }
            }
            .environment(\.settingsPaneID, "appearance")
        }

        /// The `Neon.magenta` strip stands in for the real row's live palette
        /// reads (checkmark tint, selected-row fill, label colors) — a flat fill
        /// is what a pixel test can count unambiguously.
        private func row(_ id: String) -> some View {
            Button {} label: {
                HStack(spacing: sz(12)) {
                    Rectangle().fill(Neon.magenta).frame(width: sz(60), height: sz(28))
                    DetachedChild(cardHi: true)
                    Text(id).foregroundStyle(Neon.textPrimary)
                    Spacer(minLength: sz(12))
                }
                .padding(.vertical, sz(6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A custom `View` type nested in a section's content closure that does NOT
    /// observe `ThemeStore` and whose stored property is a compile-time constant,
    /// so SwiftUI's value comparison finds it unchanged and can keep the memoized
    /// body — the case `NeonSection.card`'s interior `.id()` was documented to
    /// exist for ("the caller's closure, which can embed arbitrary non-observing
    /// custom view types from any file"). `cardHi` marks the instance nested
    /// INSIDE a row (under the row's own explicit `.id()`), `terminal` the one
    /// beside the rows; the two positions answer different questions.
    private struct DetachedChild: View {
        var cardHi = false
        var body: some View {
            Rectangle().fill(cardHi ? Neon.cardHi : Neon.terminal)
                .frame(width: sz(60), height: sz(28))
        }
    }

    /// Pixels matching each of `targets`, sampled on a coarse grid over the whole
    /// view — layout-independent, so it answers "did ANY row keep stale pixels"
    /// without the test having to know where the rows landed.
    private func matchCounts(_ view: NSView, _ targets: [NSColor], step: Int = 3) throws -> [Int] {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var counts = [Int](repeating: 0, count: targets.count)
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                for (i, t) in targets.enumerated()
                where abs(c.redComponent - t.redComponent) < 0.02
                    && abs(c.greenComponent - t.greenComponent) < 0.02
                    && abs(c.blueComponent - t.blueComponent) < 0.02 {
                    counts[i] += 1
                }
            }
        }
        return counts
    }

    /// #100 — the guard for #082's machinery being removed. Three claims in one
    /// select, all measured in pixels:
    ///
    /// 1. Theme rows carrying a STABLE, generation-independent explicit `.id()`
    ///    inside `NeonScroll`'s `LazyVStack` repaint. #082 said the lazy
    ///    container's id-keyed reuse pool served the previously-rendered row for
    ///    such an id; with #089's `NeonCardModifier` fix in place it does not.
    /// 2. Neither does it shield a subtree UNDER that stable row id: the
    ///    `cardHi` child, deliberately built to be memoized (no store
    ///    observation, constant stored property), repaints too. That is the
    ///    reason `AppearanceSettingsPane.rowAnchor` no longer folds `generation`.
    /// 3. The `terminal` child, sitting in the section's content closure beside
    ///    the rows, repaints ONLY because `NeonSection.card`'s interior
    ///    `.id("neon-section-content:…")` tears it down. Delete that id and this
    ///    test fails on that probe alone — which is why it stayed.
    func testStableRowIDsRepaintOnSelect() throws {
        resetThemeGlobals()
        defer { resetThemeGlobals() }
        // Probe order: row strip, child beside the rows, child inside a row —
        // stale reference then fresh reference for each.
        let probes = [
            try reference(ThemePalette.default.magenta),
            try reference(Color(hex: Self.probeMagentaHex)!),
            try reference(ThemePalette.default.terminal),
            try reference(Color(hex: Self.probeTerminalHex)!),
            try reference(ThemePalette.default.cardHi),
            try reference(Color(hex: Self.probeCardHiHex)!),
        ]
        let names = ["theme rows", "child beside the rows", "child under a row's stable .id()"]

        let h = host(ThemeListProbe(), side: 420, height: 480)
        let before = try matchCounts(h, probes)
        try selectProbeTheme()
        flush(h)
        let after = try matchCounts(h, probes)

        for (i, name) in names.enumerated() {
            let (stale, fresh) = (2 * i, 2 * i + 1)
            // Nothing rendered would make the rest vacuously true.
            XCTAssertGreaterThan(before[stale], 0, "\(name): must actually render before the select")
            // Zero stale pixels is the whole question. The fresh count only has
            // to be non-zero — the thing is still on screen, it did not simply
            // vanish — since a stale reference also picks up a few antialiased
            // edge pixels elsewhere in the frame, so an exact before/after match
            // would be over-tight.
            XCTAssertEqual(after[stale], 0,
                           "\(name): kept STALE pixels after select (was \(before[stale]))")
            XCTAssertGreaterThan(after[fresh], 0, "\(name): must still be on screen after select")
        }
    }
}
