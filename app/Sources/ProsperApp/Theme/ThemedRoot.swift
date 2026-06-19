import SwiftUI

/// Wrap a window's root content in this so a theme switch redraws it instantly.
/// It observes `ThemeStore.generation` and keys the content on it: when the
/// active theme changes, SwiftUI discards the old subtree and rebuilds a fresh
/// one, so every `Neon.*` color is re-read from the new palette. Also forces the
/// theme's color scheme so system controls match.
///
/// ponytail: the `.id(generation)` rebuild drops transient view state (scroll
/// offset, field focus) on switch. That only happens on an explicit, rare theme
/// change, and it buys us zero churn across the ~290 `Neon.*` call sites — no
/// need to thread an @Environment palette through every view. Worth it.
struct Themed<Content: View>: View {
    @ObservedObject private var theme = ThemeStore.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .preferredColorScheme(theme.appearance.colorScheme)
            .id(theme.generation)
    }
}
