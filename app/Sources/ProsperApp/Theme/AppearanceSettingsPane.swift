import AppKit
import SwiftUI

/// Settings → Appearance. Lists the selectable themes (built-in Default plus any
/// contributed by an installed theme extension) and switches between them. The
/// switch is instant: tapping a row re-skins every window live.
struct AppearanceSettingsPane: View {
    @ObservedObject private var theme = ThemeStore.shared
    /// Keyboard focus for the theme list: while focused, ↑/↓ move the selection
    /// and apply the theme live (see `moveSelection`). SwiftUI's focus system is
    /// exclusive, so this is automatically false — and the arrows silently do
    /// nothing here — whenever some other control (e.g. the sidebar search
    /// field) holds focus instead.
    @FocusState private var themeListFocused: Bool

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
                ForEach(Array(theme.available.enumerated()), id: \.element.id) { idx, d in
                    if idx > 0 { NeonDivider() }
                    row(d)
                }
            }
            .focusable()
            .focused($themeListFocused)
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            // The pane starts with the list focused, so arrows work right away —
            // no click needed first.
            .onAppear { themeListFocused = true }

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

    /// Arrow-key row navigation: moves off the currently active theme and
    /// applies the new one immediately, same call as clicking a row.
    private func moveSelection(_ delta: Int) {
        let list = theme.available
        guard let current = list.firstIndex(where: { $0.id == theme.activeID }),
              let next = Self.nextThemeIndex(current: current, delta: delta, count: list.count)
        else { return }
        theme.select(id: list[next].id)
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
            theme.select(id: d.id)
            // A click reclaims list focus too, so arrows keep working right
            // after — same "pick up where you clicked" contract as the sidebar.
            themeListFocused = true
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
