import SwiftUI

// MARK: - Palette
//
// Prosper's identity is the neon-blue Vulcan app icon: an electric cyan outline
// over a deep blue-black field. The Settings UI mirrors that — a cyberpunk
// console aesthetic (Cyberpunk 2077 / Raycast): near-black surfaces, sharp neon
// edges, glow, and uppercase machine labels. All tokens live here so panes stay
// declarative and the look stays consistent.

// Tokens are now backed by the active theme (see Theme/Theme.swift). Each member
// reads the live `ThemePalette` from `ThemeRuntime`, so a theme switch re-skins
// every call site. The default theme reproduces the original values byte-for-byte
// (ThemePalette.default), so the look is unchanged until a theme overrides a
// token. Derived tokens (stroke + the two gradients) are computed from the base
// colors, so theming the twelve colors re-tints them automatically.
enum Neon {
    private static var p: ThemePalette { ThemeRuntime.palette }

    // Accents
    static var blue: Color { p.blue }              // electric cyan-blue
    static var blueBright: Color { p.blueBright }  // hot highlight
    static var indigo: Color { p.indigo }          // cool secondary
    static var magenta: Color { p.magenta }        // danger / pop
    static var terminal: Color { p.terminal }      // robotic terminal-green

    // Surfaces (deep blue-black, never pure grey)
    static var bgTop: Color { p.bgTop }
    static var bgBottom: Color { p.bgBottom }
    static var sidebar: Color { p.sidebar }
    static var card: Color { p.card }
    static var cardHi: Color { p.cardHi }

    // Lines + text
    static var stroke: Color { p.blue.opacity(0.16) }
    static var textPrimary: Color { p.textPrimary }
    static var textSecondary: Color { p.textSecondary }

    static var cardStroke: LinearGradient {
        LinearGradient(colors: [p.blue.opacity(0.38), p.indigo.opacity(0.10)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var barFill: LinearGradient {
        LinearGradient(colors: [p.blueBright, p.blue, p.indigo],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Backdrop

/// Cyberpunk console backdrop: a deep blue-black vertical gradient lit by two
/// faint neon glows (cyan top-left, indigo bottom-right) plus a hairline scanline
/// veil. Painted behind every Settings surface.
struct SettingsBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Neon.blue.opacity(0.14), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Neon.indigo.opacity(0.12), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card + section

private struct NeonCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Neon.card))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Neon.cardStroke, lineWidth: 1))
            .shadow(color: Neon.blue.opacity(0.10), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func neonCard() -> some View { modifier(NeonCardModifier()) }
}

/// A titled card block. The title is a machine-style uppercase label with a
/// glowing neon tick; the body is a rounded, neon-edged card. An optional footer
/// renders as a muted caption beneath the card.
/// Builds a title where the `accent` substring is tinted bright neon to visually
/// pop — a trailing run (e.g. "QuickLinks" with accent "Links") or a leading one
/// (e.g. "Window Management" with accent "Window"). The base keeps whatever
/// foreground style the caller applies; only the accent run is recolored.
func neonAccentedText(_ title: String, accent: String?) -> Text {
    guard let accent, title.count > accent.count else { return Text(title) }
    if title.hasSuffix(accent) {
        return Text(String(title.dropLast(accent.count))) + Text(accent).foregroundColor(Neon.blueBright)
    }
    if title.hasPrefix(accent) {
        return Text(accent).foregroundColor(Neon.blueBright) + Text(String(title.dropFirst(accent.count)))
    }
    return Text(title)
}

struct NeonSection<Content: View>: View {
    let title: String?
    let accent: String?
    let footer: String?
    /// When non-nil the section is collapsible and this binding drives + persists
    /// its state (callers back it with @AppStorage). Nil = always expanded.
    let collapsed: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, accent: String? = nil, footer: String? = nil,
         collapsed: Binding<Bool>? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.footer = footer
        self.collapsed = collapsed
        self.content = content
    }

    private var collapsible: Bool { collapsed != nil }
    private var isCollapsed: Bool { collapsed?.wrappedValue ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                titleRow(title)
            }
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCard()
                if let footer {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(Neon.textSecondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func titleRow(_ title: String) -> some View {
        let label = HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Neon.blue)
                .frame(width: 3, height: 12)
                .shadow(color: Neon.blue.opacity(0.9), radius: 4)
            neonAccentedText(title, accent: accent)
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Neon.textSecondary)
            if collapsible {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Neon.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
        }
        .padding(.leading, 2)

        if let collapsed {
            Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed.wrappedValue.toggle() } } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// Scrolling content column shared by every pane. Owns the backdrop, padding and
/// the consistent column width so panes only declare their sections.
struct NeonScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsBackground())
        .tint(Neon.blue)
        .foregroundStyle(Neon.textPrimary)
    }
}

// MARK: - Rows

/// A label + trailing control row (the workhorse layout inside cards).
struct NeonRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        // Center, not firstTextBaseline: a two-line title (title + subtitle) must
        // not push trailing controls (badge, buttons) up to the first line — they
        // read as misaligned. Center keeps them vertically centered in the card.
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Neon.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Neon.textSecondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

/// Hairline used to separate sub-rows inside a single card.
struct NeonDivider: View {
    var body: some View {
        Rectangle().fill(Neon.stroke).frame(height: 1)
    }
}

// MARK: - Stat tile

/// A Raycast-style metric tile: oversized neon number above a muted caption,
/// with a soft glow. Used for the Statistics dashboard.
struct NeonStatTile: View {
    let value: String
    let label: String
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Neon.blue)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Neon.blueBright)
                .shadow(color: Neon.blue.opacity(0.45), radius: 8)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Neon.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .neonCard()
    }
}

// MARK: - Buttons

/// Outlined neon button — the default action style inside Settings.
struct NeonButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        let accent = destructive ? Neon.magenta : Neon.blue
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? Color.white : accent)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.30 : 0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accent.opacity(0.55), lineWidth: 1))
            .shadow(color: accent.opacity(configuration.isPressed ? 0.4 : 0.18), radius: 6)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == NeonButtonStyle {
    static var neon: NeonButtonStyle { NeonButtonStyle() }
    static var neonDestructive: NeonButtonStyle { NeonButtonStyle(destructive: true) }
}

// MARK: - Floating panel chrome
//
// Shared by the borderless floating panels (command runner, clipboard history)
// so they wear the same neon-console skin as Settings: a deep blue-black
// gradient surface lit by a faint cyan glow, a neon hairline edge, forced dark
// scheme, and a cyan tint for any system controls inside.

private struct NeonPanelSurface: ViewModifier {
    var corner: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                                   startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [Neon.blue.opacity(0.10), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 460)
                    RadialGradient(colors: [Neon.indigo.opacity(0.08), .clear],
                                   center: .bottomTrailing, startRadius: 0, endRadius: 480)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Neon.cardStroke, lineWidth: 1))
            .preferredColorScheme(.dark)
            .tint(Neon.blue)
    }
}

extension View {
    /// Wraps a floating panel's content in the neon console surface (gradient +
    /// glow + neon edge + dark scheme + cyan tint).
    func neonPanelSurface(corner: CGFloat = 12) -> some View {
        modifier(NeonPanelSurface(corner: corner))
    }
}

// MARK: - Sidebar

/// One destination in the Settings sidebar.
struct SettingsTab: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    /// Optional trailing substring of `title` tinted bright neon (e.g. "Links" in
    /// "QuickLinks") so the second word pops in the rail.
    var accent: String? = nil
}

/// Vertical, grouped navigation rail. Each group has an uppercase header; the
/// selected row glows with a neon fill and a left accent bar.
struct SettingsSidebar: View {
    let groups: [(String, [SettingsTab])]
    @Binding var selection: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.0)
                            .font(.system(size: 10, weight: .bold))
                            .textCase(.uppercase).tracking(1.4)
                            .foregroundStyle(Neon.textSecondary.opacity(0.7))
                            .padding(.leading, 12).padding(.bottom, 2)
                        ForEach(group.1) { tab in
                            row(tab)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .frame(width: 218)
        .background(
            ZStack {
                Neon.sidebar
                LinearGradient(colors: [Neon.blue.opacity(0.06), .clear],
                               startPoint: .top, endPoint: .bottom)
            })
        .overlay(alignment: .trailing) {
            Rectangle().fill(Neon.stroke).frame(width: 1)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Neon.blue)
                .shadow(color: Neon.blue.opacity(0.8), radius: 6)
            Text("PROSPER")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Neon.textPrimary)
        }
        .padding(.leading, 10)
        .padding(.bottom, 4)
    }

    private func row(_ tab: SettingsTab) -> some View {
        let selected = selection == tab.id
        return Button {
            selection = tab.id
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Neon.blue)
                    .frame(width: 3, height: 18)
                    .shadow(color: Neon.blue.opacity(0.9), radius: 4)
                    .opacity(selected ? 1 : 0)
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Neon.blueBright : Neon.textSecondary)
                neonAccentedText(tab.title, accent: tab.accent)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Neon.textPrimary : Neon.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Neon.blue.opacity(0.14) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Neon.blue.opacity(selected ? 0.45 : 0), lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
