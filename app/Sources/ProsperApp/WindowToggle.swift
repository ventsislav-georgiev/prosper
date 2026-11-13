import AppKit

/// #1102: the one rule for every global shortcut that opens a Prosper window or panel (Agent
/// Sessions, Settings, Coding Agent, Clipboard History, the runner and Translate). Closed,
/// miniaturized or hidden: open it and focus it. Open but not focused: focus it, never close it.
/// Focused: close it. Only the hotkeys toggle; menu items and buttons keep opening or focusing.
enum WindowToggle {
    enum Effect: Equatable { case open, focus, close }

    static func effect(shown: Bool, focused: Bool) -> Effect {
        guard shown else { return .open }
        return focused ? .close : .focus
    }

    /// The state read, a seam: a test cannot put a window on screen or make it key.
    /// Shown: on screen and not in the Dock (a hidden app's windows are not visible either).
    /// Focused: the key window, the one the keyboard types into. A titled window is key only while
    /// Prosper is active; the runner and clipboard are non-activating panels, which a click makes key
    /// while another app stays active, so `NSApp.isActive` would call a panel the user types in unfocused.
    @MainActor static var state: (NSWindow) -> (shown: Bool, focused: Bool) = {
        ($0.isVisible && !$0.isMiniaturized, $0.isKeyWindow)
    }

    /// Runs the effect the rule picks for `window` (nil: never built, or torn down on close).
    @MainActor static func apply(_ window: NSWindow?, open: () -> Void, focus: () -> Void, close: () -> Void) {
        let s = window.map(state) ?? (shown: false, focused: false)
        switch effect(shown: s.shown, focused: s.focused) {
        case .open: open()
        case .focus: focus()
        case .close: close()
        }
    }

    /// The frontmost app, a seam (#1113): a test hands the panels a fake one.
    @MainActor static var frontmost: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }

    /// #1102: a panel brought back by its hotkey pastes into the app the user went to meanwhile, never
    /// into Prosper itself; with Prosper (or nothing) frontmost the old target stays.
    @MainActor static func pasteTarget(kept: NSRunningApplication?) -> NSRunningApplication? {
        guard let app = frontmost(), app.processIdentifier != getpid() else { return kept }
        return app
    }
}
