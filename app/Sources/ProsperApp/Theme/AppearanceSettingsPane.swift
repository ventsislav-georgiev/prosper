import AppKit
import SwiftUI

/// Settings → Appearance. Lists the selectable themes (built-in Default plus any
/// contributed by an installed theme extension) and switches between them. The
/// switch is instant: tapping a row re-skins every window live.
struct AppearanceSettingsPane: View {
    @ObservedObject private var theme = ThemeStore.shared

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
                        footer: "An extension can ship a theme via [[contributes.themes]]. One theme is active at a time.") {
                ForEach(Array(theme.available.enumerated()), id: \.element.id) { idx, d in
                    if idx > 0 { NeonDivider() }
                    row(d)
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
        }
    }

    // Discrete presets, not sliders: changing size/opacity bumps the theme
    // `generation`, which rebuilds the whole window via `.id()`. A continuous
    // slider drag would get its gesture state torn out from under it on every
    // step; segmented taps rebuild once per change, cleanly.
    static let sizePresets: [CGFloat] = [0.85, 1.0, 1.15, 1.3]
    static let opacityPresets: [CGFloat] = [1.0, 0.9, 0.8, 0.7]

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func percent(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))%" }

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
