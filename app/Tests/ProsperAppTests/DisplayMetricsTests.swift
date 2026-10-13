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

    /// An unset scale must read as 1.0 (full size); an unset opacity defaults to
    /// 0.9 (the v2.127.0 slightly-transparent launch default). tearDown restores
    /// the saved values.
    func testUnsetPreferencesDefaultToOne() {
        let d = Preferences.defaults
        d.removeObject(forKey: "prosper.uiScale")
        d.removeObject(forKey: "prosper.uiOpacity")
        XCTAssertEqual(Preferences.uiScale, 1.0)
        XCTAssertEqual(Preferences.uiOpacity, 0.9)
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
        Preferences.defaults.removeObject(forKey: "prosper.uiFrost")
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
        let store = ThemeStore(defaults: scratchDefaults("dm"), cacheDir: tmpCache())
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
        let store = ThemeStore(defaults: scratchDefaults("dm"), cacheDir: tmpCache())
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
        let store = ThemeStore(defaults: scratchDefaults("dm"), cacheDir: tmpCache())
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

    // MARK: #426 — Settings width

    /// A window sized at a small UI scale (min 820 x 0.75 = 615) stays that narrow
    /// when a larger UI size raises contentMinSize (the min only blocks user
    /// resizes); the shared clamp must grow it back. Private window, never shown.
    @MainActor
    func testWindowBelowRaisedContentMinSizeIsClamped() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        func content() -> NSSize { win.contentRect(forFrameRect: win.frame).size }
        func width() -> CGFloat { content().width }
        // setFrame(_:display:) does not clamp to the min (#427: pins the helper, not the OS).
        win.contentMinSize = NSSize(width: 820, height: 480)
        win.setFrame(NSRect(x: 100, y: 100, width: 610, height: 700), display: false)
        XCTAssertLessThan(width(), 820, "precondition: setFrame leaves the window below the min")
        win.clampToContentMinSize()
        XCTAssertGreaterThanOrEqual(width(), 820)

        win.contentMinSize = NSSize(width: 615, height: 360)
        win.setContentSize(NSSize(width: 615, height: 400))
        win.contentMinSize = NSSize(width: 820, height: 480)
        XCTAssertLessThan(width(), 820, "precondition: raising the min leaves the window below it")
        win.clampToContentMinSize()
        XCTAssertGreaterThanOrEqual(content().width, 820)
        XCTAssertGreaterThanOrEqual(content().height, 480)

        // Height only, less short than the title bar: a clamp reading frame.size misses it.
        win.setContentSize(NSSize(width: 900, height: 460))
        win.clampToContentMinSize()
        XCTAssertGreaterThanOrEqual(content().height, 480, "content height, not frame height, is clamped")

        // Flush with the right edge of a 1920 x 1080 screen: the grown window stays on it.
        // The visible rect is passed in, so no real screen is involved.
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        win.contentMinSize = NSSize(width: 615, height: 360)
        win.setContentSize(NSSize(width: 615, height: 400))
        win.setFrameOrigin(NSPoint(x: visible.maxX - win.frame.width, y: 100))
        win.contentMinSize = NSSize(width: 820, height: 480)
        win.clampToContentMinSize(within: visible)
        XCTAssertGreaterThanOrEqual(width(), 820)
        XCTAssertLessThanOrEqual(win.frame.maxX, visible.maxX, "grown window pushed off the right edge")
        XCTAssertGreaterThanOrEqual(win.frame.minY, visible.minY)

        // On the bottom edge: setContentSize keeps the top-left, so growing the height
        // pushes the window below visible.minY; the clamp lifts it back (#428).
        win.contentMinSize = NSSize(width: 615, height: 360)
        win.setContentSize(NSSize(width: 900, height: 400))
        win.setFrameOrigin(NSPoint(x: 100, y: visible.minY))
        win.contentMinSize = NSSize(width: 820, height: 480)
        win.clampToContentMinSize(within: visible)
        XCTAssertGreaterThanOrEqual(content().height, 480)
        XCTAssertEqual(win.frame.minY, visible.minY, "grown window pushed off the bottom edge")

        // Wider than the visible rect: the left edge wins over the right (#428).
        let narrow = NSRect(x: 100, y: 0, width: 600, height: 1080)
        win.contentMinSize = NSSize(width: 615, height: 360)
        win.setContentSize(NSSize(width: 615, height: 400))
        win.setFrameOrigin(NSPoint(x: 300, y: 100))
        win.contentMinSize = NSSize(width: 820, height: 480)
        win.clampToContentMinSize(within: narrow)
        XCTAssertGreaterThan(win.frame.width, narrow.width, "precondition: the grown window is wider than the visible rect")
        XCTAssertEqual(win.frame.minX, narrow.minX, "a window wider than the visible rect keeps its left edge on it")
    }

    /// The no-argument clamp forwards the window's own screen (#428, QM3): a private
    /// window on the bottom edge of the main screen's visible frame is lifted back
    /// onto it. Never ordered front; skipped on a host with no screen.
    @MainActor
    func testClampWithoutRectKeepsWindowOnItsScreen() throws {
        guard let main = NSScreen.main?.visibleFrame else { throw XCTSkip("no screen on this host") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 615, height: 400),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        win.contentMinSize = NSSize(width: 615, height: 360)
        win.setFrameOrigin(NSPoint(x: main.minX + 50, y: main.minY))
        guard let visible = win.screen?.visibleFrame else { throw XCTSkip("no screen on this host") }
        win.contentMinSize = NSSize(width: 820, height: 480)
        win.clampToContentMinSize()
        XCTAssertGreaterThanOrEqual(win.contentRect(forFrameRect: win.frame).height, 480)
        XCTAssertGreaterThanOrEqual(win.frame.minY, visible.minY, "grown window pushed off the bottom of its screen")
    }

    /// The theme hook's per-window step (AppDelegate.applyThemeToAppKit) raises the
    /// Settings minimum on a live UI-size change and must grow the open window (#427, QM2).
    /// At 0.7 the minimum is floored at the 85% width (#428), so a hook that inlines
    /// 820 x scale fails there.
    @MainActor
    func testThemedWindowSizingGrowsSettingsWindow() {
        for scale: CGFloat in [0.7, 1.0] {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 615, height: 400),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            win.identifier = SettingsWindow.themedIdentifier
            win.contentMinSize = NSSize(width: 615, height: 360)
            AppDelegate.applyThemedWindowSizing([win], scale: scale)
            let size = win.contentRect(forFrameRect: win.frame).size
            let min = SettingsWindow.contentMinSize(scale: scale)
            XCTAssertEqual(win.contentMinSize, min, "scale \(scale)")
            XCTAssertGreaterThanOrEqual(win.contentMinSize.width, 697, "scale \(scale)")
            XCTAssertGreaterThanOrEqual(size.width, min.width, "scale \(scale)")
            XCTAssertGreaterThanOrEqual(size.height, min.height, "scale \(scale)")
        }
    }

    /// Segmented controls keep their natural width at every UI size; the Settings
    /// minimum must leave the widest row (Calendar Font style) and the Statistics
    /// Activity controls inside their card at every preset (#427, #428). Card row =
    /// content - sidebar 218 - scroll padding 2x26 - card padding 2x16 = content - 302,
    /// all scaled.
    @MainActor
    func testSettingsMinimumFitsWidestSegmentedRows() {
        func minWidth<V: View>(_ v: V) -> CGFloat {
            NSHostingController(rootView: v).sizeThatFits(in: NSSize(width: 1, height: 10_000)).width
        }
        for scale in AppearanceSettingsPane.sizePresets {
            ThemeRuntime.scale = scale
            let room = SettingsWindow.contentMinSize(scale: scale).width - 302 * scale
            let font = minWidth(NeonRow("Font style") { CalendarFontStylePicker(design: .constant(.standard)) })
            XCTAssertLessThanOrEqual(font, room, "Font style row overflows its card at the minimum window, scale \(scale)")
            let activity = minWidth(ActivityControls(metric: .constant(.completions), rangeDays: .constant(30)))
            XCTAssertLessThanOrEqual(activity, room, "Activity controls overflow their card at the minimum window, scale \(scale)")
            // #429: at the card's room, 1.0 keeps one row, 0.85 stacks with natural-width pickers.
            guard scale == 1.0 || scale == 0.85 else { continue }
            let pickerH = NSHostingController(rootView: Picker("", selection: .constant(0)) { Text("7d").tag(0) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()).sizeThatFits(in: NSSize(width: 10_000, height: 10_000)).height
            let fit = NSHostingController(rootView: ActivityControls(metric: .constant(.completions), rangeDays: .constant(30)))
                .sizeThatFits(in: NSSize(width: room, height: 10_000))
            if scale == 1.0 {
                XCTAssertLessThanOrEqual(fit.height, pickerH + 2, "Activity controls stacked at room \(room), scale 1.0")
            } else {
                XCTAssertGreaterThanOrEqual(fit.height, 2 * pickerH + sz(8) - 0.5, "Activity controls did not stack at room \(room), scale \(scale)")
                XCTAssertLessThanOrEqual(fit.width, room, "Stacked Activity controls overflow at room \(room), scale \(scale)")
                XCTAssertGreaterThanOrEqual(activity, fit.width - 0.5, "Activity pickers compress below their natural width, scale \(scale)")
            }
        }
    }

    /// The System Stats Display picker ("Text | Graph | Text + Graph") must reserve
    /// its segmented control's natural width; a fixed frame narrower than it made the
    /// control overflow the card.
    @MainActor
    func testDisplayPickerReservesItsSegmentedWidth() {
        func segmented(in v: NSView) -> NSSegmentedControl? {
            v as? NSSegmentedControl ?? v.subviews.lazy.compactMap(segmented).first
        }
        for scale: CGFloat in [1.0, 1.25] {
            ThemeRuntime.scale = scale
            let host = NSHostingView(rootView: StatsDisplayModePicker(mode: .constant(.both)))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            guard let seg = segmented(in: host) else { return XCTFail("no NSSegmentedControl at scale \(scale)") }
            XCTAssertGreaterThanOrEqual(host.fittingSize.width, seg.intrinsicContentSize.width - 0.5,
                                        "row reserves less than the control draws at scale \(scale)")
        }
    }

    // MARK: helpers

    private func tmpCache() -> URL {
        tempDir("dm")
    }
}
