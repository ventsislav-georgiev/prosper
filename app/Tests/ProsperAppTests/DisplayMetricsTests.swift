import XCTest
import SwiftUI
@testable import ProsperApp

/// UI size + transparency: the 1:1 default guarantee, preset snapping, preference
/// clamping, ThemeStore live-apply wiring, and the per-render hot-path budget for
/// the `sz()`/`op()`/`Neon.font` multipliers that every view body calls.
final class DisplayMetricsTests: XCTestCase {

    // Saved globals — these are process-wide and shared with the running app's
    // singletons, so each test restores them to the 1.0 identity on exit.
    private var savedScale: CGFloat = 1.0
    private var savedOpacity: CGFloat = 1.0
    private var savedFrost = false
    private var savedPrefScale: Double = 1.0
    private var savedPrefOpacity: Double = 1.0
    private var savedPrefFrost = false

    override func setUp() {
        super.setUp()
        savedScale = ThemeRuntime.scale
        savedOpacity = ThemeRuntime.opacity
        savedFrost = ThemeRuntime.frost
        savedPrefScale = Preferences.uiScale
        savedPrefOpacity = Preferences.uiOpacity
        savedPrefFrost = Preferences.uiFrost
    }

    override func tearDown() {
        ThemeRuntime.scale = savedScale
        ThemeRuntime.opacity = savedOpacity
        ThemeRuntime.frost = savedFrost
        Preferences.uiScale = savedPrefScale
        Preferences.uiOpacity = savedPrefOpacity
        Preferences.uiFrost = savedPrefFrost
        super.tearDown()
    }

    // MARK: 1:1 default guarantee

    /// The whole design rests on multiplier identity: at scale/opacity 1.0 every
    /// scaled literal must equal the original. If this breaks, the default UI is no
    /// longer pixel-identical to the un-scaled baseline.
    func testIdentityAtDefaultMetrics() {
        ThemeRuntime.scale = 1.0
        ThemeRuntime.opacity = 1.0
        for v in [0, 1, 2, 6, 8, 12, 14, 18, 28, 96, 200, 820] as [CGFloat] {
            XCTAssertEqual(sz(v), v, "sz must be identity at scale 1.0")
        }
    }

    func testScaleMultiplies() {
        ThemeRuntime.scale = 1.3
        XCTAssertEqual(sz(10), 13, accuracy: 0.0001)
        ThemeRuntime.scale = 0.85
        XCTAssertEqual(sz(20), 17, accuracy: 0.0001)
    }

    // MARK: preference clamping

    func testScalePreferenceClamps() {
        Preferences.uiScale = 99
        XCTAssertEqual(Preferences.uiScale, Preferences.uiScaleRange.upperBound)
        Preferences.uiScale = 0
        XCTAssertEqual(Preferences.uiScale, Preferences.uiScaleRange.lowerBound)
        Preferences.uiScale = 1.15
        XCTAssertEqual(Preferences.uiScale, 1.15, accuracy: 0.0001)
    }

    func testOpacityPreferenceClamps() {
        Preferences.uiOpacity = 99
        XCTAssertEqual(Preferences.uiOpacity, Preferences.uiOpacityRange.upperBound)
        Preferences.uiOpacity = 0
        XCTAssertEqual(Preferences.uiOpacity, Preferences.uiOpacityRange.lowerBound)
    }

    /// An unset key must read as 1.0 (full size / fully opaque) — the launch default
    /// that keeps a fresh install pixel-identical to the old build. tearDown restores
    /// the saved values.
    func testUnsetPreferencesDefaultToOne() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "prosper.uiScale")
        d.removeObject(forKey: "prosper.uiOpacity")
        XCTAssertEqual(Preferences.uiScale, 1.0)
        XCTAssertEqual(Preferences.uiOpacity, 1.0)
    }

    // MARK: preset snapping

    func testNearestSnapsToClosestPreset() {
        let s = AppearanceSettingsPane.sizePresets
        XCTAssertEqual(AppearanceSettingsPane.nearest(1.0, in: s), 1.0)
        XCTAssertEqual(AppearanceSettingsPane.nearest(1.14, in: s), 1.15)
        XCTAssertEqual(AppearanceSettingsPane.nearest(0.0, in: s), s.first, "below-range snaps to lowest preset")
        XCTAssertEqual(AppearanceSettingsPane.nearest(9.0, in: s), s.max(), "above-range snaps to highest preset")
    }

    func testPercentFormat() {
        XCTAssertEqual(AppearanceSettingsPane.percent(1.0), "100%")
        XCTAssertEqual(AppearanceSettingsPane.percent(0.85), "85%")
        XCTAssertEqual(AppearanceSettingsPane.percent(1.15), "115%")
    }

    @MainActor
    func testEffectiveOpacityFullIsAlwaysFull() {
        // 1.0 maps to 1.0 on both branches (reduce-transparency on or off), so this
        // is stable regardless of the test machine's accessibility setting.
        XCTAssertEqual(ThemeStore.effectiveOpacity(1.0), 1.0)
    }

    // MARK: Frost — preference + precedence

    /// Unset Frost key reads false: a fresh install gets the original opaque look,
    /// not surprise frosted glass. tearDown restores the saved value.
    func testFrostPreferenceDefaultsFalse() {
        UserDefaults.standard.removeObject(forKey: "prosper.uiFrost")
        XCTAssertFalse(Preferences.uiFrost)
    }

    func testFrostPreferenceRoundTrips() {
        Preferences.uiFrost = true
        XCTAssertTrue(Preferences.uiFrost)
        Preferences.uiFrost = false
        XCTAssertFalse(Preferences.uiFrost)
    }

    /// The full precedence truth table (pure overload, deterministic regardless of
    /// the test machine's accessibility setting): frost is on iff the user enabled
    /// it AND system Reduce-transparency is off.
    @MainActor
    func testEffectiveFrostPrecedence() {
        XCTAssertTrue(ThemeStore.effectiveFrost(true, reduceTransparency: false))
        XCTAssertFalse(ThemeStore.effectiveFrost(true, reduceTransparency: true),
                       "Reduce transparency must force frost off even when the user enabled it")
        XCTAssertFalse(ThemeStore.effectiveFrost(false, reduceTransparency: false))
        XCTAssertFalse(ThemeStore.effectiveFrost(false, reduceTransparency: true))
    }

    @MainActor
    func testSetFrostMirrorsBumpsBackdropTickAndDedups() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "dm-\(UUID())")!, cacheDir: tmpCache())
        var hookFired = 0
        store.onChange = { hookFired += 1 }
        let g0 = store.generation
        let t0 = store.backdropTick
        store.setFrost(true)
        XCTAssertTrue(store.frost)
        XCTAssertTrue(Preferences.uiFrost, "must persist to the preference")
        XCTAssertEqual(ThemeRuntime.frost, ThemeStore.effectiveFrost(true),
                       "must mirror the effective value into the render-thread global")
        XCTAssertGreaterThan(store.backdropTick, t0, "frost change must bump backdropTick to re-render backdrops")
        XCTAssertEqual(store.generation, g0, "frost is backdrop-only — must NOT bump generation (no full teardown)")
        XCTAssertEqual(hookFired, 1, "AppKit reconcile hook (flips window isOpaque) must fire once")

        // Redundant set is a no-op: no extra re-render, no extra hook.
        let t1 = store.backdropTick
        store.setFrost(true)
        XCTAssertEqual(store.backdropTick, t1)
        XCTAssertEqual(hookFired, 1)
    }

    // MARK: ThemeStore live-apply wiring

    @MainActor
    func testSetScaleMirrorsAndBumpsGeneration() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "dm-\(UUID())")!, cacheDir: tmpCache())
        var hookFired = 0
        store.onChange = { hookFired += 1 }
        let g0 = store.generation
        store.setScale(1.3)
        XCTAssertEqual(store.scale, 1.3, accuracy: 0.0001)
        XCTAssertEqual(ThemeRuntime.scale, 1.3, accuracy: 0.0001, "must mirror into the render-thread global")
        XCTAssertGreaterThan(store.generation, g0, "scale change must bump generation for full rebuild")
        XCTAssertEqual(hookFired, 1, "AppKit reconcile hook must fire once")

        // Redundant set is a no-op: no extra rebuild, no extra hook.
        let g1 = store.generation
        store.setScale(1.3)
        XCTAssertEqual(store.generation, g1)
        XCTAssertEqual(hookFired, 1)
    }

    @MainActor
    func testSetOpacityMirrorsAndClamps() {
        let store = ThemeStore(defaults: UserDefaults(suiteName: "dm-\(UUID())")!, cacheDir: tmpCache())
        let g0 = store.generation
        let t0 = store.backdropTick
        store.setOpacity(0.7)
        XCTAssertEqual(store.opacity, 0.7, accuracy: 0.0001)
        // ThemeRuntime gets the *effective* opacity (downgraded to 1.0 only when the
        // system Reduce-transparency setting is on).
        XCTAssertEqual(ThemeRuntime.opacity, ThemeStore.effectiveOpacity(0.7), accuracy: 0.0001)
        XCTAssertGreaterThan(store.backdropTick, t0, "opacity is backdrop-only — bumps backdropTick, not generation")
        XCTAssertEqual(store.generation, g0, "opacity change must NOT trigger a full-window teardown")

        // Out-of-range request is clamped by the preference, then a redundant clamp
        // lands on the same stored value → no second bump.
        store.setOpacity(0.05)
        XCTAssertEqual(store.opacity, CGFloat(Preferences.uiOpacityRange.lowerBound), accuracy: 0.0001)
    }

    // MARK: hot path — sz()/op()/Neon.font run on every view body evaluation

    func testMetricMultiplierHotPathBudget() {
        ThemeRuntime.scale = 1.15
        let iters = 200_000
        let start = Date()
        var sink: CGFloat = 0
        for i in 0..<iters {
            sink += sz(CGFloat(i & 31))
            withExtendedLifetime(Neon.font(13)) { sink += 1 }
        }
        let ns = Date().timeIntervalSince(start) / Double(iters) * 1_000_000_000
        print("metric multiplier bundle: \(Int(ns)) ns/iter over \(iters) (sink=\(sink))")
        // sz is a read+multiply; Neon.font builds a Font. Generous ceiling — the point
        // is to catch a regression that puts disk/lock work on the render path.
        XCTAssertLessThan(ns, 20_000, "sz/Neon.font bundle must stay well under 20µs/iter")
    }

    // MARK: hot path — Frost backdrop fill decision runs on every render
    //
    // The launcher/clipboard/chat/settings backdrops re-evaluate this exact ternary
    // on every SwiftUI invalidation, which for the runner is per keystroke (typing
    // mutates results → RunnerView body → neonPanelSurface body). REQUIREMENT:
    // `backdropFillOpacity` is pure arithmetic over static vars (a frost-branch read
    // plus, under frost, a multiply of two more) — inlined into a render its cost is
    // single-digit ns; measured here through the @inline(never) barrier it is ~tens of
    // ns (call + static-accessor overhead dominates). It must never grow disk/lock
    // work. Ceiling is generous to absorb CI noise — the point is to catch a
    // regression that moves real work onto it, not to police a few ns of jitter.
    func testFrostBackdropFillHotPathBudget() {
        ThemeRuntime.frost = true
        ThemeRuntime.opacity = 0.8
        let iters = 500_000
        var sink: CGFloat = 0
        for _ in 0..<10_000 { sink += Self.readFill() }   // warm
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iters { sink += Self.readFill() }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iters)
        print("frost backdrop fill decision hot path: \(String(format: "%.1f", perCall)) ns/call over \(iters) iters (sink=\(sink))")
        XCTAssertLessThan(perCall, 200, "frost backdrop fill decision exceeded the 200ns hot-path budget")
    }

    /// Reads the REAL backdrop-fill property (not a copy) through an `@inline(never)`
    /// barrier so the optimizer can't hoist the static reads out of the loop and
    /// report a fake ~0ns. Exercises the same code path every render uses.
    @inline(never)
    private static func readFill() -> CGFloat { ThemeRuntime.backdropFillOpacity }

    // MARK: Frost — backdrop fill (Transparency tunes the glass density)

    /// `backdropFillOpacity` is the single source every backdrop fades to. Non-frost
    /// returns the plain transparency. Frost maps the Transparency presets (1.0…0.7)
    /// onto a wide, visible glass-tint range (frostSurfaceOpacity…frostTintMin): 100%
    /// preserves the original frost look, lower presets thin the tint so more blurred
    /// desktop shows. Monotonic and clamped at both ends.
    func testBackdropFillFrostTracksTransparency() {
        ThemeRuntime.frost = false
        ThemeRuntime.opacity = 0.7
        XCTAssertEqual(ThemeRuntime.backdropFillOpacity, 0.7, accuracy: 0.0001,
                       "non-frost backdrop = plain opacity")

        ThemeRuntime.frost = true
        ThemeRuntime.opacity = 1.0
        XCTAssertEqual(ThemeRuntime.backdropFillOpacity, ThemeRuntime.frostSurfaceOpacity, accuracy: 0.0001,
                       "frost at 100% = the densest glass tint (original look preserved)")

        ThemeRuntime.opacity = CGFloat(Preferences.uiOpacityRange.lowerBound)
        XCTAssertEqual(ThemeRuntime.backdropFillOpacity, ThemeRuntime.frostTintMin, accuracy: 0.0001,
                       "frost at the lowest preset = the thinnest glass tint")

        // The Transparency control has a real, perceptible effect under frost: each
        // step down thins the glass. The mid presets must be strictly between the ends.
        ThemeRuntime.opacity = 0.9
        let mid = ThemeRuntime.backdropFillOpacity
        XCTAssertGreaterThan(mid, ThemeRuntime.frostTintMin)
        XCTAssertLessThan(mid, ThemeRuntime.frostSurfaceOpacity)
        XCTAssertGreaterThan(ThemeRuntime.frostSurfaceOpacity - ThemeRuntime.frostTintMin, 0.3,
                             "the tint range must be wide enough to actually see")
    }

    // MARK: Frost — window isOpaque wiring (Chat/Settings)

    /// The invariant that makes Frost actually work on titled windows: the
    /// `.behindWindow` blur can only sample the desktop through a NON-opaque window,
    /// so Frost must force `isOpaque = false` even at full opacity (where a non-frost
    /// window stays opaque). Runs on a real NSWindow.
    @MainActor
    func testApplyWindowOpacityForcesNonOpaqueUnderFrost() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                           styleMask: [.titled], backing: .buffered, defer: true)

        ThemeRuntime.frost = false
        ThemeRuntime.opacity = 1.0
        SettingsWindow.applyWindowOpacity(win)
        XCTAssertTrue(win.isOpaque, "no frost + full opacity = opaque (original look)")

        ThemeRuntime.frost = true
        SettingsWindow.applyWindowOpacity(win)
        XCTAssertFalse(win.isOpaque, "frost must force non-opaque even at full opacity (blur needs it)")

        ThemeRuntime.frost = false
        ThemeRuntime.opacity = 0.8
        SettingsWindow.applyWindowOpacity(win)
        XCTAssertFalse(win.isOpaque, "transparency below 1.0 is non-opaque regardless of frost")
    }

    // MARK: helpers

    private func tmpCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dm-\(UUID().uuidString)", isDirectory: true)
    }
}
