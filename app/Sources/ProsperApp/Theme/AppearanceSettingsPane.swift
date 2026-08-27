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

            // #084: no explicit `.id()` anywhere in this section — the swatches
            // don't need a `SettingsFocusRouter` scroll target (no arrow-key nav
            // here, just clicks), so there's nothing that needs its own identity
            // at all. That sidesteps the whole #078/#082 "explicit id nested in a
            // LazyVStack child" bug class outright rather than having to get a
            // generation-fold right: this section's selected-state checkmark
            // repaints the same way `UI Size`/`Transparency`'s pickers already do
            // — reading `theme.menuBarIconChoice` live from inside `content()`,
            // no id trick needed (see `ThemeStore.menuBarIconChoice`'s comment).
            NeonSection("Menu Bar Icon",
                        footer: "Applies immediately. Native symbols and the Vulcan preset use the menu bar's own black/white tinting; other emoji show in full color.") {
                VStack(alignment: .leading, spacing: sz(10)) {
                    HStack(spacing: sz(10)) {
                        iconSwatch(.prosper, label: "Prosper")
                        iconSwatch(.vulcan, label: "Vulcan")
                        ForEach(MenuBarIconChoice.sfSymbolOptions, id: \.self) { name in
                            iconSwatch(.sfSymbol(name), label: Self.sfSymbolLabel(name))
                        }
                    }
                    HStack(spacing: sz(8)) {
                        Text("Custom emoji").font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                        TextField("🙂", text: customEmojiBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: sz(64))
                        if isCustomEmojiActive {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Neon.blueBright)
                        }
                    }
                    HStack(spacing: sz(8)) {
                        Text("Icon Size").font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                        Picker("", selection: Binding(
                            get: { theme.menuBarIconSize },
                            set: { theme.setMenuBarIconSize($0) })) {
                            ForEach(MenuBarIconSize.allCases, id: \.self) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: sz(180))
                    }
                }
            }

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
                // it: this whole subtree sits inside this "Theme" NeonSection's
                // interior content id (#078 round 6 moved it off the section's own
                // outer node onto the VStack wrapping `content()` — see
                // `NeonSection.card`), which is torn down and rebuilt on EVERY
                // select — click or arrow-driven, since
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
                //
                // #078/#082: the id folds in `theme.generation` (see
                // `rowAnchor`'s comment) so each row's identity changes on every
                // select, same as the section's own interior content id — a row
                // that kept a generation-INDEPENDENT id here is what caused the
                // v2.141.0 regression (the list never repainting on select; see
                // `rowAnchor`).
                //
                // #090: rendered in `orderedThemes` (dark group, then light —
                // see `orderedByAppearance`), NOT raw `theme.available` order.
                // `moveSelection` below walks that same `orderedThemes` list so
                // ↑/↓ tracks the rows actually on screen.
                VStack(alignment: .leading, spacing: sz(14)) {
                    ForEach(Array(orderedThemes.enumerated()), id: \.element.id) { idx, d in
                        if idx > 0 { NeonDivider() }
                        row(d).id(Self.rowAnchor(pane: paneID, themeID: d.id, generation: theme.generation))
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
        // NeonSection's interior content id (#078 round 6, see `NeonSection.card`)
        // — so it mounts once when this pane appears and unmounts once when it disappears,
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
    ///
    /// #082 (v2.141.0 QA, regression from #078 round 6): folds `generation` in
    /// too, same as `NeonSection.card`'s interior content id. Without this the
    /// row kept the SAME explicit id across a select (only `pane`/`themeID`,
    /// both unchanged by picking a different theme) while its ANCESTOR (the
    /// section's interior content id) changed — an explicit `.id()` nested
    /// inside a `LazyVStack` whose own realization/reuse bookkeeping is
    /// literally keyed by explicit ids (the mechanism #078 round 6 already
    /// established corrupts *scroll range* when stacked at the LazyVStack's
    /// own direct-child boundary) let the row's PREVIOUS rendered content
    /// survive the ancestor's teardown intact — stale colors, stale checkmark
    /// position — even though the row is self-observing (`AppearanceSettingsPane`
    /// holds `@ObservedObject theme`) and its body closure genuinely does run
    /// fresh on every select: self-observation makes SwiftUI DESCRIBE fresh
    /// content, but the row's unchanged id let the lazy container's own reuse
    /// pool substitute cached content for that identity anyway, which is why
    /// only a full pane remount (a new identity from further up) ever cleared
    /// it. Folding `generation` into the id, like the section's own interior
    /// key, invalidates that reuse-pool entry every select. `moveSelection`
    /// (below) computes the matching value for `SettingsFocusRouter` — read
    /// `theme.generation` only AFTER `theme.select(id:)` so it's the value the
    /// rebuilt row will actually carry.
    static func rowAnchor(pane: String, themeID: String, generation: Int) -> SettingsAnchor {
        SettingsAnchor(pane: pane, section: "theme-row:\(themeID):\(generation)")
    }

    /// #090: stable sort — all `.dark`-appearance themes first, then all
    /// `.light`, preserving each group's existing relative (registry/
    /// discovery) order. `Array.sorted(by:)` is a stable sort as of Swift 5,
    /// so two themes of the same appearance never swap: the comparator
    /// returns `false` for either ordering of a tied pair, which is exactly
    /// what stability requires. Pure + free of `ThemeStore`, so it's
    /// unit-testable without a live store. Display-only: never reorders
    /// `theme.available` (the registry/storage list) itself — see
    /// `orderedThemes`, the only call site, and `moveSelection` below, which
    /// walks this same order so ↑/↓ matches the rows on screen.
    static func orderedByAppearance(_ themes: [ThemeDescriptor]) -> [ThemeDescriptor] {
        themes.sorted { $0.appearance == .dark && $1.appearance != .dark }
    }

    /// The theme list as actually rendered (and navigated) — see
    /// `orderedByAppearance`. Default is `.dark` and already sorts first in
    /// `theme.available` (see `ThemeStore.setAvailable`), so it stays first
    /// here too.
    private var orderedThemes: [ThemeDescriptor] { Self.orderedByAppearance(theme.available) }

    /// Arrow-key row navigation: moves off the currently active theme, applies
    /// the new one immediately (same call as clicking a row), then asks
    /// NeonScroll to scroll the new row into view — minimal movement only
    /// (`scrollAnchor: nil`; SwiftUI leaves the viewport alone when the target
    /// is already fully visible). A CLICK never does this: the clicked row is
    /// visible by definition, and round-1/2 QA already established that a
    /// select must not otherwise move the scroll position.
    private func moveSelection(_ delta: Int) {
        let list = orderedThemes
        guard let current = list.firstIndex(where: { $0.id == theme.activeID }),
              let next = Self.nextThemeIndex(current: current, delta: delta, count: list.count)
        else { return }
        let id = list[next].id
        theme.select(id: id)
        // Read `theme.generation` AFTER select (it bumps synchronously, see
        // `ThemeStore.apply`) so this matches the id the rebuilt row will
        // actually carry — see `rowAnchor`'s comment.
        SettingsFocusRouter.shared.request(
            Self.rowAnchor(pane: paneID, themeID: id, generation: theme.generation), scrollAnchor: nil)
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

    /// The bundled default icon, for an accurate "Prosper" swatch preview —
    /// same PNG `MenuBarController.setMenuBarImage` falls back to. Loaded once;
    /// nil (rare — a broken bundle) just drops to a plain glyph in the picker.
    private static let prosperPreviewImage: NSImage? =
        Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    /// Friendly title for a handful of known SF Symbol names; anything else
    /// (there is nothing else today — see `MenuBarIconChoice.sfSymbolOptions`)
    /// falls back to a capitalized raw name so a future addition never crashes.
    private static func sfSymbolLabel(_ name: String) -> String {
        switch name {
        case "sparkles": return "Sparkles"
        case "bolt.fill": return "Bolt"
        case "command": return "Command"
        case "terminal": return "Terminal"
        case "cpu": return "CPU"
        default: return name.capitalized
        }
    }

    /// One selectable icon swatch: a small preview (rendered the same way it
    /// will actually look — SF symbols and the Vulcan preset go through the
    /// same real menu-bar tinting, see `menuBarTint`/`emojiGlyph`, #093) plus
    /// a label, highlighted like a theme row when it's the active choice.
    private func iconSwatch(_ choice: MenuBarIconChoice, label: String) -> some View {
        let selected = theme.menuBarIconChoice == choice
        return Button {
            theme.setMenuBarIconChoice(choice)
        } label: {
            VStack(spacing: sz(4)) {
                Group {
                    switch choice {
                    case .prosper:
                        if let img = Self.prosperPreviewImage {
                            Image(nsImage: img).resizable().scaledToFit()
                        } else {
                            Image(systemName: "star.fill")
                        }
                    case .sfSymbol(let name):
                        // #093: was plain `Image(systemName: name)`, which
                        // (like everything else in this Group) inherited
                        // `.foregroundStyle(Neon.textPrimary)` below — the
                        // active THEME's text color, not the real menu bar's
                        // black/white template tint. Same class of bug as
                        // Vulcan, just less jarring (still monochrome): a
                        // light Prosper theme's dark `textPrimary` would
                        // preview a dark glyph even while the system menu bar
                        // (dark) actually renders it white. No NSImage/
                        // `templateImage()` round-trip needed here — SF
                        // symbols are vector-rendered natively by SwiftUI, so
                        // overriding just the tint is the whole fix.
                        Image(systemName: name)
                            .foregroundStyle(Self.menuBarTint)
                    case .emoji(let value):
                        // Only reachable via the Vulcan swatch (the only
                        // `.emoji` choice ever passed to `iconSwatch` — see
                        // `body` above; free-typed custom emoji has its own
                        // separate preview-less field). Extracted to its own
                        // `@ViewBuilder` (rather than an inline `if`/`else`
                        // here) — the type checker chokes on the combined
                        // branch complexity otherwise.
                        Self.emojiGlyph(value, choice: choice)
                    }
                }
                .font(Neon.font(16))
                .frame(width: sz(28), height: sz(28))
                .foregroundStyle(Neon.textPrimary)
                Text(label).font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
            }
            .padding(sz(6))
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

    /// #093: the `.emoji` swatch glyph — full color, except the Vulcan preset
    /// which previews the exact template `NSImage` the menu bar renders
    /// (`MenuBarIconChoice.templateImage()` — never re-rasterized here),
    /// tinted `menuBarTint`. SwiftUI does not auto-tint a template `NSImage`
    /// the way AppKit does, so `.renderingMode(.template)` +
    /// `.foregroundStyle` stands in for AppKit's own `isTemplate` tinting.
    /// Any other `.emoji` value (defensive — not reachable today, see the
    /// call site in `iconSwatch`) keeps rendering full color, matching #088.
    @ViewBuilder
    private static func emojiGlyph(_ value: String, choice: MenuBarIconChoice) -> some View {
        if value == MenuBarIconChoice.vulcanEmoji, let img = choice.templateImage() {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Self.menuBarTint)
        } else {
            Text(value)
        }
    }

    /// #093: the color a template menu-bar image (SF symbols, the Vulcan
    /// preset) actually renders as in the real menu bar — matches AppKit's
    /// own template-image tinting exactly (plain white/black, not e.g.
    /// `.labelColor`, which could drift from what a real status item shows).
    /// See `MenuBarTint.isSystemDark`'s doc for why this has to read the real
    /// system appearance rather than `theme.appearance` (tracks the selected
    /// Prosper THEME, which can disagree) or this window's own hardcoded
    /// `.darkAqua` (`SettingsWindow.swift`).
    private static var menuBarTint: Color { MenuBarTint.isSystemDark ? .white : .black }

    /// Reads/writes the custom-emoji field straight off `theme.menuBarIconChoice`
    /// — no local `@State` needed, same "Binding(get:set:) over ThemeStore" idiom
    /// as the UI Size/Transparency pickers above. Every keystroke applies
    /// immediately (including invalid input): `MenuBarIconChoice.templateImage()`
    /// already returns nil for anything that fails `isValidEmoji`, which sends
    /// `MenuBarController.setMenuBarImage` back to the default icon — so garbage
    /// here degrades gracefully for free, with no separate validation path in
    /// this view. Never shows the Vulcan preset's own emoji, so picking Vulcan
    /// doesn't make the custom field look independently "filled in".
    private var customEmojiBinding: Binding<String> {
        Binding(
            get: {
                if case .emoji(let v) = theme.menuBarIconChoice, v != MenuBarIconChoice.vulcanEmoji { return v }
                return ""
            },
            set: { theme.setMenuBarIconChoice(.emoji($0)) })
    }

    private var isCustomEmojiActive: Bool {
        if case .emoji(let v) = theme.menuBarIconChoice, v != MenuBarIconChoice.vulcanEmoji, !v.isEmpty {
            return true
        }
        return false
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
/// QA broke: the theme list sits inside the "Theme" NeonSection's interior
/// content id (#078 round 6 moved it off the section's own outer node onto the
/// VStack wrapping `content()` — see `NeonSection.card` in SettingsTheme.swift),
/// torn down and rebuilt on every select — including an arrow-driven one,
/// since `moveSelection` calls the same `theme.select(id:)` as a click.
/// Destroying the focused view mid-interaction handed first responder to the
/// next key view (the sidebar search field), stealing focus after the very
/// first press or click.
///
/// This view is attached via `.background(...)` OUTSIDE that interior content
/// id's subtree (see `AppearanceSettingsPane.body`), so its own mount/dismount is
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
