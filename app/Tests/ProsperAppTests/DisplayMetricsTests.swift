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
    private var savedPrefScale: Double = 1.0
    private var savedPrefOpacity: Double = 1.0

    override func setUp() {
        super.setUp()
        savedScale = ThemeRuntime.scale
        savedOpacity = ThemeRuntime.opacity
        savedPrefScale = Preferences.uiScale
        savedPrefOpacity = Preferences.uiOpacity
    }

    override func tearDown() {
        ThemeRuntime.scale = savedScale
        ThemeRuntime.opacity = savedOpacity
        Preferences.uiScale = savedPrefScale
        Preferences.uiOpacity = savedPrefOpacity
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
        XCTAssertEqual(AppearanceSettingsPane.nearest(0.5, in: s), 0.85, "below-range snaps to lowest preset")
        XCTAssertEqual(AppearanceSettingsPane.nearest(9.0, in: s), 1.3, "above-range snaps to highest preset")
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
        store.setOpacity(0.7)
        XCTAssertEqual(store.opacity, 0.7, accuracy: 0.0001)
        // ThemeRuntime gets the *effective* opacity (downgraded to 1.0 only when the
        // system Reduce-transparency setting is on).
        XCTAssertEqual(ThemeRuntime.opacity, ThemeStore.effectiveOpacity(0.7), accuracy: 0.0001)
        XCTAssertGreaterThan(store.generation, g0)

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

    // MARK: helpers

    private func tmpCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dm-\(UUID().uuidString)", isDirectory: true)
    }
}
