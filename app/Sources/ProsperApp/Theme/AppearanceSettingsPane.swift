import SwiftUI

/// Settings → Appearance. Lists the selectable themes (built-in Default plus any
/// contributed by an installed theme extension) and switches between them. The
/// switch is instant: tapping a row re-skins every window live.
struct AppearanceSettingsPane: View {
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        NeonScroll {
            VStack(alignment: .leading, spacing: 3) {
                Text("Appearance")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Neon.textPrimary)
                Text("Choose a theme. Install more from the Extensions tab.")
                    .font(.system(size: 12)).foregroundStyle(Neon.textSecondary)
            }
            .padding(.bottom, 2)

            NeonSection("Theme",
                        footer: "An extension can ship a theme via [[contributes.themes]]. One theme is active at a time.") {
                ForEach(Array(theme.available.enumerated()), id: \.element.id) { idx, d in
                    if idx > 0 { NeonDivider() }
                    row(d)
                }
            }
        }
    }

    private func row(_ d: ThemeDescriptor) -> some View {
        let selected = theme.activeID == d.id
        let palette = theme.previews[d.id] ?? .default
        return Button {
            theme.select(id: d.id)
        } label: {
            HStack(spacing: 12) {
                swatches(palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.title).foregroundStyle(Neon.textPrimary)
                    Text(d.isBuiltIn ? "Built-in · \(d.appearance.rawValue)" : "\(d.id) · \(d.appearance.rawValue)")
                        .font(.caption).foregroundStyle(Neon.textSecondary)
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Neon.blueBright)
                        .shadow(color: Neon.blue.opacity(0.6), radius: 4)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A tiny preview strip: background, accent, secondary accent, text.
    private func swatches(_ p: ThemePalette) -> some View {
        HStack(spacing: 0) {
            ForEach(Array([p.bgTop, p.blue, p.indigo, p.magenta, p.textPrimary].enumerated()), id: \.offset) { _, c in
                Rectangle().fill(c).frame(width: 12, height: 28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Neon.stroke, lineWidth: 1))
    }
}
