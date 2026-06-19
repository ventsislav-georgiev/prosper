import AppKit

/// Temporarily shows a Dock icon (and a Cmd-Tab entry) while any Prosper window
/// is on screen.
///
/// Prosper runs as an `.accessory` agent (set at launch in main.swift) so it has no Dock tile and
/// its floating panels never appear in Cmd-Tab. The downside: once the user
/// clicks another app, an open Prosper window (command runner, clipboard history,
/// settings, …) is left behind in the background with no way to bring it forward —
/// no Dock icon to click, no Cmd-Tab entry to switch to.
///
/// This tracks how many tracked windows are currently visible. While at least one
/// is visible (and the user hasn't disabled the Dock icon in Settings) the app is
/// `.regular` — a Dock icon and Cmd-Tab entry appear; otherwise it's `.accessory`.
///
/// Ordering matters: the policy must become `.regular` *before* the app activates,
/// otherwise the app activates while still `.accessory` and macOS never records it
/// as a recently-active regular app — leaving it stuck at the bottom of the
/// Cmd-Tab stack. So `windowDidShow` both flips the policy and re-activates, and
/// callers must invoke it before their own `NSApp.activate` / `makeKeyAndOrderFront`.
@MainActor
enum DockPolicy {
    /// Identities of the windows currently counted as visible. A set makes the
    /// register/unregister calls idempotent (a double `windowDidHide` is a no-op)
    /// and naturally ref-counts when several windows are open at once. Membership
    /// is tracked regardless of the user's preference; `apply()` decides the policy.
    private static var visible = Set<ObjectIdentifier>()

    /// Marks `window` as visible and reconciles the activation policy. Call this
    /// BEFORE activating the window so the `.regular` flip lands before activation.
    static func windowDidShow(_ window: NSWindow) {
        visible.insert(ObjectIdentifier(window))
        apply()
    }

    /// Marks `window` as hidden and reconciles the activation policy (drops the
    /// Dock icon once the last visible window is gone).
    static func windowDidHide(_ window: NSWindow) {
        visible.remove(ObjectIdentifier(window))
        apply()
    }

    /// Re-evaluates the policy after the "Show Dock icon" preference changes, so
    /// toggling it takes effect immediately on any currently-open window.
    static func preferenceChanged() {
        apply()
    }

    /// Sets `.regular` (Dock icon + Cmd-Tab) when the icon is enabled and a window
    /// is visible, else `.accessory`. On the transition into `.regular` it also
    /// activates the app so the freshly-shown window rises to the top of the
    /// Cmd-Tab stack rather than being appended at the bottom.
    private static func apply() {
        let wantRegular = Preferences.showDockIcon && !visible.isEmpty
        let target: NSApplication.ActivationPolicy = wantRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}
