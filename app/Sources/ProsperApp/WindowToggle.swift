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

    /// The key window, a seam (#1121): a test cannot make a window key.
    @MainActor static var keyWindow: () -> NSWindow? = { NSApplication.shared.keyWindow }

    /// #1121: what the last pasteTarget() named, shared by the runner and Clipboard History. Read only while
    /// Prosper is in front with no own window key; dropped when Prosper resigns active (r2). Internal for tests.
    @MainActor static var openedOver: NSRunningApplication?

    /// #1102/#1121: the one rule for which app a paste from the runner or Clipboard History goes to, asked when
    /// the panel opens or comes back by its hotkey (main queue, before the panel activates Prosper). Another app
    /// in front: that app. Prosper in front with one of its own windows key (Settings, Agent Sessions; not a
    /// non-activating panel): Prosper, the paste lands in that window. Otherwise Prosper is in front only because
    /// a panel put it there, or was just closed, or nothing is: the app the last answer named, none if it quit.
    @MainActor static func pasteTarget() -> NSRunningApplication? {
        observeResign()
        if let app = frontmost(), app.processIdentifier != getpid()
            || keyWindow().map({ !$0.styleMask.contains(.nonactivatingPanel) }) == true {
            openedOver = app
            return app
        }
        return openedOver?.isTerminated == false ? openedOver : nil
    }

    /// #1121 r2: the remembered app holds only while Prosper has stayed active since the answer that named it;
    /// once Prosper resigns, another app is in front and the next answer names that one.
    @MainActor static func prosperResignedActive() { openedOver = nil }

    @MainActor private static var resignObserver: NSObjectProtocol?

    /// Installed by the first pasteTarget(), the only writer of openedOver. queue .main runs the block on the
    /// main thread, so assumeIsolated holds (the block itself is not main-actor isolated).
    @MainActor private static func observeResign() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { WindowToggle.prosperResignedActive() } }
    }
}
