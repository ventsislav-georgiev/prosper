import SwiftUI

/// Wrap a window's root content in this so a theme switch redraws it instantly.
/// It observes `ThemeStore.generation` and keys the content on it: when the
/// active theme changes, SwiftUI discards the old subtree and rebuilds a fresh
/// one, so every `Neon.*` color is re-read from the new palette. Also forces the
/// theme's color scheme so system controls match.
///
/// ponytail: the `.id()` rebuild drops transient view state (scroll offset,
/// field focus) on switch. That only happens on an explicit, rare theme change,
/// and it buys us zero churn across the ~290 `Neon.*` call sites — no need to
/// thread an @Environment palette through every view. Worth it.
///
/// `rebuildOnSizeChangeOnly` (default false) keys the rebuild on `generation`,
/// which bumps on both a theme swap AND a UI-size change — the right choice for
/// a window whose content does not observe `ThemeStore` itself. Pass `true` for
/// a window whose content already self-observes `ThemeStore` for a live palette
/// swap (see SettingsBackground / NeonPanelSurface / SettingsSidebar /
/// AppearanceSettingsPane, all `@ObservedObject theme = ThemeStore.shared`):
/// it then keys on `scale` alone, so a plain theme *select* no longer tears the
/// subtree down (only a size change still does) — fixes #078: switching themes
/// in Settings → Appearance was resetting the theme list's scroll position on
/// every tap, because it sat inside this `.id()`'d subtree like everything else.
struct Themed<Content: View>: View {
    @ObservedObject private var theme = ThemeStore.shared
    var rebuildOnSizeChangeOnly: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .preferredColorScheme(theme.appearance.colorScheme)
            .id(rebuildOnSizeChangeOnly ? AnyHashable(theme.scale) : AnyHashable(theme.generation))
    }
}
