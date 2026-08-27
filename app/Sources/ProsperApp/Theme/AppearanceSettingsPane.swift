import AppKit
import SwiftUI

/// Settings → Appearance. Lists the selectable themes (built-in Default plus any
/// contributed by an installed theme extension) and switches between them. The
/// switch is instant: tapping a row re-skins every window live.
struct AppearanceSettingsPane: View {
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.settingsPaneID) private var paneID

    var body: some View {
        NeonScroll {
            VStack(alignment: .leading, spacing: sz(3)) {
                Text("Appearance")
                    .font(Neon.font(22, weight: .bold, design: .rounded))
                    .foregroundStyle(Neon.textPrimary)
                Text("Choose a theme. Install more from the Extensions tab.")
                    .font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
            }
            .padding(.bottom, sz(2))

            NeonSection("Theme",
                        footer: "An extension can ship a theme via [[contributes.themes]]. One theme is active at a time. ↑/↓ moves the selection.") {
                // The list of rows is its own VStack (not just the bare ForEach)
                // so `spacing: sz(14)` reproduces the gap the section's own VStack
                // used to provide when the ForEach was its only, and therefore
                // un-spaced-from-siblings, child.
                //
                // ↑/↓ navigation is NOT SwiftUI focus (`.focusable()`/`@FocusState`/
                // `.onKeyPress`) — that was round 2's approach, and round 3 QA (a
                // click stealing focus to the sidebar search field) traced back to
                // it: this whole subtree sits inside this "Theme" NeonSection's own
                // `.id(theme.generation)` (see `NeonSection.card`), which is torn
                // down and rebuilt on EVERY select — click or arrow-driven, since
                // `moveSelection` calls the same `theme.select(id:)` — and
                // destroying the focused view mid-interaction handed first
                // responder to the next key view (the search field). See
                // `KeyHandling` below: a window-scoped NSEvent monitor, attached
                // outside this `.id()`'d subtree, replaces it — no focus is ever
                // claimed, so there's nothing for AppKit to reassign.
                //
                // Each row also carries a `SettingsFocusRouter` anchor `.id()`
                // (#078 round 4) so `moveSelection` can ask NeonScroll's own
                // ScrollViewReader — which this view has no direct handle to —
                // to scroll an off-screen arrow-selected row into view. See
                // `moveSelection` for why a click never does this.
                VStack(alignment: .leading, spacing: sz(14)) {
                    ForEach(Array(theme.available.enumerated()), id: \.element.id) { idx, d in
                        if idx > 0 { NeonDivider() }
                        row(d).id(Self.rowAnchor(pane: paneID, themeID: d.id))
                    }
                }
            }

            NeonSection("UI Size", accent: "Size",
                        footer: "Scales all text and spacing across Prosper. Affects every window.") {
                Picker("", selection: Binding(
                    get: { Self.nearest(theme.scale, in: Self.sizePresets) },
                    set: { theme.setScale($0) })) {
                    ForEach(Self.sizePresets, id: \.self) { v in
                        Text(Self.percent(v)).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            NeonSection("Transparency", accent: "Transparency",
                        footer: reduceTransparency
                            ? "System “Reduce transparency” is on, so windows stay opaque."
                            : theme.frost
                                ? "Tunes the frosted glass: lower shows more of the blurred desktop through it."
                                : "Lets the desktop show through Prosper’s windows.") {
                Picker("", selection: Binding(
                    get: { Self.nearest(theme.opacity, in: Self.opacityPresets) },
                    set: { theme.setOpacity($0) })) {
                    ForEach(Self.opacityPresets, id: \.self) { v in
                        Text(Self.percent(v)).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(reduceTransparency)
            }

            NeonSection("Frost", accent: "Frost",
                        footer: reduceTransparency
                            ? "System “Reduce transparency” is on, so Frost is unavailable."
                            : "Frosted glass: blurs the desktop behind Prosper’s windows. Use Transparency to tune the glass.") {
                Toggle(isOn: Binding(
                    get: { theme.frost },
                    set: { theme.setFrost($0) })) {
                    Text("Frosted glass background").foregroundStyle(Neon.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Neon.blue)
                .disabled(reduceTransparency)
            }
        }
        // Attached OUTSIDE NeonScroll's content closure — i.e. outside every
        // NeonSection's own `.id(theme.generation)`'d subtree — so it mounts
        // once when this pane appears and unmounts once when it disappears,
        // untouched by a theme select's teardown/rebuild in between. See
        // `KeyHandling` below.
        .background(KeyHandling(onUp: { moveSelection(-1) }, onDown: { moveSelection(1) }))
    }

    // Discrete presets, not sliders: changing size bumps the theme `generation`,
    // which still rebuilds the whole Settings window via `.id()` (see
    // ThemedRoot.swift — only a plain theme *select* was narrowed to refresh in
    // place for #078; size still needs every sz()-driven layout constant
    // recomputed fresh). A continuous slider drag would get its gesture state
    // torn out from under it on every step; segmented taps rebuild once per
    // change, cleanly. (Opacity/frost are lighter — they only bump `backdropTick`
    // and never tear the window down; see ThemeStore.setOpacity/setFrost.)
    static let sizePresets: [CGFloat] = [0.7, 0.85, 1.0, 1.15, 1.3, 1.45]
    static let opacityPresets: [CGFloat] = [1.0, 0.9, 0.8, 0.75, 0.65, 0.5, 0.35]

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func percent(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))%" }

    /// ↑ (delta -1) / ↓ (delta +1) from `current` into a list of `count` themes.
    /// Pure + no wrap-around: nil past either end (including an empty list), so
    /// the caller simply does nothing at the ends. Kept free of `ThemeStore` so
    /// it is testable headlessly.
    static func nextThemeIndex(current: Int, delta: Int, count: Int) -> Int? {
        let next = current + delta
        return (0..<count).contains(next) ? next : nil
    }

    /// Whether `KeyHandling`'s NSEvent monitor should consume a keyDown as list
    /// navigation. Pure so this is testable without a live NSEvent/window: only
    /// up/down arrows (kVK_UpArrow 126 / kVK_DownArrow 125) are ever candidates,
    /// and only while the Appearance pane is visible and the window's first
    /// responder isn't a text-input view (so typing in the sidebar search field,
    /// including its own cursor-movement arrows, is never intercepted).
    static func shouldSwallowArrowKey(paneVisible: Bool, firstResponderIsTextInput: Bool, keyCode: UInt16) -> Bool {
        guard paneVisible, !firstResponderIsTextInput else { return false }
        return keyCode == 126 || keyCode == 125
    }

    /// A theme row's `SettingsFocusRouter`/`ScrollViewReader` scroll-target id.
    /// Namespaced ("theme-row:") so it can never collide with a `NeonSection`
    /// title anchor (`SettingsAnchor(pane:section:)` with `section` a plain
    /// title like "Theme") — see `NeonSection.anchor` in SettingsTheme.swift —
    /// so `SettingsFocusRouter.highlight`'s section-glow never lights up for it.
    static func rowAnchor(pane: String, themeID: String) -> SettingsAnchor {
        SettingsAnchor(pane: pane, section: "theme-row:\(themeID)")
    }

    /// Arrow-key row navigation: moves off the currently active theme, applies
    /// the new one immediately (same call as clicking a row), then asks
    /// NeonScroll to scroll the new row into view — minimal movement only
    /// (`scrollAnchor: nil`; SwiftUI leaves the viewport alone when the target
    /// is already fully visible). A CLICK never does this: the clicked row is
    /// visible by definition, and round-1/2 QA already established that a
    /// select must not otherwise move the scroll position.
    private func moveSelection(_ delta: Int) {
        let list = theme.available
        guard let current = list.firstIndex(where: { $0.id == theme.activeID }),
              let next = Self.nextThemeIndex(current: current, delta: delta, count: list.count)
        else { return }
        let id = list[next].id
        theme.select(id: id)
        SettingsFocusRouter.shared.request(Self.rowAnchor(pane: paneID, themeID: id), scrollAnchor: nil)
    }

    /// Snap an arbitrary stored value to the closest preset so the segmented
    /// control always shows a selection even after clamping or a manual default edit.
    static func nearest(_ v: CGFloat, in presets: [CGFloat]) -> CGFloat {
        presets.min(by: { abs($0 - v) < abs($1 - v) }) ?? 1.0
    }

    private func row(_ d: ThemeDescriptor) -> some View {
        let selected = theme.activeID == d.id
        let palette = theme.previews[d.id] ?? .default
        return Button {
            // Selecting is all a click does — it never touches first responder,
            // so keyboard focus (e.g. the sidebar search field) stays exactly
            // where it was. Arrows keep working regardless: see `KeyHandling`.
            theme.select(id: d.id)
        } label: {
            HStack(spacing: sz(12)) {
                swatches(palette)
                VStack(alignment: .leading, spacing: sz(2)) {
                    Text(d.title).foregroundStyle(Neon.textPrimary)
                    Text(d.isBuiltIn ? "Built-in · \(d.appearance.rawValue)" : "\(d.id) · \(d.appearance.rawValue)")
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                }
                Spacer(minLength: sz(12))
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Neon.blueBright)
                        .shadow(color: Neon.blue.opacity(0.6), radius: sz(4))
                }
            }
            .padding(.vertical, sz(6))
            // Selected-row highlight — same fill + border treatment as the
            // sidebar's selected tab (SettingsSidebar.row in SettingsTheme.swift).
            .background(
                RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                    .fill(selected ? Neon.blue.opacity(0.14) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                            .strokeBorder(Neon.blue.opacity(selected ? 0.45 : 0), lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A tiny preview strip: background, accent, secondary accent, text.
    private func swatches(_ p: ThemePalette) -> some View {
        HStack(spacing: 0) {
            ForEach(Array([p.bgTop, p.blue, p.indigo, p.magenta, p.textPrimary].enumerated()), id: \.offset) { _, c in
                Rectangle().fill(c).frame(width: sz(12), height: sz(28))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: sz(6), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: sz(6), style: .continuous)
            .strokeBorder(Neon.stroke, lineWidth: 1))
    }
}

/// Arrow-key theme navigation via a window-scoped local NSEvent monitor — same
/// idiom as `RunnerPanel.KeyHandling` — instead of SwiftUI focus
/// (`.focusable()`/`@FocusState`/`.onKeyPress`), which round 2 used and round 3
/// QA broke: the theme list sits inside the "Theme" NeonSection's own
/// `.id(theme.generation)` (see `NeonSection.card` in SettingsTheme.swift),
/// torn down and rebuilt on every select — including an arrow-driven one,
/// since `moveSelection` calls the same `theme.select(id:)` as a click.
/// Destroying the focused view mid-interaction handed first responder to the
/// next key view (the sidebar search field), stealing focus after the very
/// first press or click.
///
/// This view is attached via `.background(...)` OUTSIDE that `.id()`'d
/// subtree (see `AppearanceSettingsPane.body`), so its own mount/dismount is
/// tied to the Appearance pane as a whole, not to individual selects:
/// `makeNSView` runs once when the pane appears, `dismantleNSView` once when
/// it disappears. No focus is ever claimed, so there's nothing for AppKit to
/// reassign, and no reinstall-per-select race to reason about.
private struct KeyHandling: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
        context.coordinator.start()
        DispatchQueue.main.async { [weak v] in context.coordinator.window = v?.window }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
        if context.coordinator.window == nil { context.coordinator.window = nsView.window }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        weak var window: NSWindow?
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let w = window, e.window === w else { return e }
            // Same "is the field editor active" check as
            // CommandWClosableWindow.sendEvent (SettingsWindow.swift) — this
            // window's own Tab-cycling override.
            let firstResponder = w.firstResponder
            let isTextInput = firstResponder is NSText || firstResponder is NSTextView
            // ponytail: paneVisible is always true here — this NSView's own
            // mount/dismount above already tracks "Appearance pane on screen";
            // there's no separate runtime signal to thread through. Kept as a
            // real parameter on the predicate (not hardcoded inside it) so
            // `shouldSwallowArrowKey` stays testable on its own.
            guard AppearanceSettingsPane.shouldSwallowArrowKey(
                paneVisible: true, firstResponderIsTextInput: isTextInput, keyCode: e.keyCode)
            else { return e }
            if e.keyCode == 126 { onUp?() } else { onDown?() }
            return nil
        }
    }
}
