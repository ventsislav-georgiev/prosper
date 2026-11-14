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
        if let app = frontmost(), app.processIdentifier != getpid() || ownWindowKey() {
            openedOver = app
            return app
        }
        return openedOver?.isTerminated == false ? openedOver : nil
    }

    /// One of Prosper's own windows is key (Settings, Agent Sessions), not a non-activating panel.
    @MainActor static func ownWindowKey() -> Bool {
        keyWindow().map { !$0.styleMask.contains(.nonactivatingPanel) } == true
    }

    /// #1121 r2: the remembered app holds only while Prosper has stayed active since the answer that named it;
    /// once Prosper resigns, another app is in front and the next answer names that one.
    @MainActor static func prosperResignedActive() { openedOver = nil }

    /// #1150 R1150-1: macOS can refuse a panel's activation, so Prosper never resigns afterwards. Prosper
    /// becoming active by anything but a panel (a Settings or Agent Sessions window, the Dock icon) drops the
    /// remembered app too; a panel's own activation (the runner or Clipboard History key) keeps it.
    @MainActor static func prosperBecameActive() {
        if keyWindow()?.styleMask.contains(.nonactivatingPanel) != true { openedOver = nil }
    }

    @MainActor private static var resignObserver: NSObjectProtocol?
    @MainActor private static var activeObserver: NSObjectProtocol?

    /// Installed by the first pasteTarget(), the only writer of openedOver. queue .main runs the blocks on the
    /// main thread, so assumeIsolated holds (the blocks themselves are not main-actor isolated).
    @MainActor private static func observeResign() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { WindowToggle.prosperResignedActive() } }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { WindowToggle.prosperBecameActive() } }
    }

    // MARK: - #1150 the paste guard

    /// Seams (#1150). Under XCTest the real ones are never installed: with no fake, nothing is activated, no
    /// key event is posted and nothing beeps, whatever paste(into:) decides. Called on main, from paste(into:).
    @MainActor static var activate: ((NSRunningApplication) -> Bool)? =
        NSClassFromString("XCTestCase") == nil ? { $0.activate(options: []) } : nil
    @MainActor static var sendCommandV: (() -> Void)? = NSClassFromString("XCTestCase") == nil ? { WindowToggle.postCommandV() } : nil
    /// The fill-in's "not sent" sound (#848). Every paste(into:) ends in exactly one of sendCommandV or beep.
    @MainActor static var beep: (() -> Void)? = NSClassFromString("XCTestCase") == nil ? { NSSound.beep() } : nil

    /// Polls of the frontmost app after the activation, 0.05 s apart: the paste goes at the first that shows
    /// the target in front (the parent's fixed 0.05 s), a slow activation gets up to 0.5 s, then the beep.
    static let frontTries = 10

    /// #1150: the runner's and Clipboard History's paste; the text is already on the clipboard. A missing or quit
    /// target gets nothing. Otherwise the target is asked to come forward and Command-V goes only if it is the
    /// frontmost app when the key goes; for Prosper itself (pasteTarget() named it because one of its own
    /// windows was key) one of its own windows must be key again. Otherwise nothing is sent, the text stays on
    /// the clipboard and the user hears the beep. Main queue throughout: every asyncAfter is on .main and every
    /// decision runs there.
    @MainActor static func paste(into target: NSRunningApplication?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {   // the panel resigns key first
            // No activation seam (XCTest with no fake) ends here too: nothing activated, nothing sent.
            guard let target, !target.isTerminated, let activate = WindowToggle.activate else { beep?(); return }
            // r2: the answer is not trusted either way (a refused or self activation can answer false with the
            // target already in front); the frontmost polls decide.
            _ = activate(target)
            sendWhenFront(target, tries: frontTries)
        }
    }

    @MainActor private static func sendWhenFront(_ target: NSRunningApplication, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if frontmost()?.processIdentifier == target.processIdentifier,
               target.processIdentifier != getpid() || ownWindowKey() {
                sendCommandV?()
            } else if tries > 1 {
                sendWhenFront(target, tries: tries - 1)
            } else {
                beep?()
            }
        }
    }

    /// Synthesizes a Cmd+V keystroke via CGEvent. Reached only through sendCommandV, never under XCTest.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
