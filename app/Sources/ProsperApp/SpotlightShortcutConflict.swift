import AppKit
import Carbon

/// Guides only the known default-launcher conflict; all other failed hotkeys keep
/// using the generic notification.
@MainActor
enum SpotlightShortcutConflict {
    private static var didPresent = false

    static func shouldPresent(isDefaultRunner: Bool,
                              spotlightUsesCommandSpace: Bool) -> Bool {
        isDefaultRunner && spotlightUsesCommandSpace
    }

    static func spotlightUsesCommandSpace() -> Bool {
        // Read-only: this is macOS's only available record of the user's Spotlight
        // shortcut. Never write the undocumented AppleSymbolicHotKeys preference.
        guard let keys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") else { return false }
        return spotlightUsesCommandSpace(keys)
    }

    static func spotlightUsesCommandSpace(_ keys: [String: Any]) -> Bool {
        guard let spotlight = keys["64"] as? [String: Any],
              (spotlight["enabled"] as? Bool ?? (spotlight["enabled"] as? Int == 1)),
              let value = spotlight["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              (parameters[1] as? NSNumber)?.uint32Value == UInt32(kVK_Space),
              (parameters[2] as? NSNumber)?.uint32Value
                == UInt32(NSEvent.ModifierFlags.command.rawValue) else { return false }
        return true
    }

    static func presentIfNeeded() {
        guard !didPresent else { return }
        didPresent = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "⌘Space is assigned to Spotlight"
        alert.informativeText = "Prosper’s default launcher shortcut could not be enabled because Spotlight is using ⌘Space. Open Keyboard Shortcuts to disable or rebind Spotlight, then try again."
        alert.addButton(withTitle: "Open Keyboard Shortcuts")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let specific = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?KeyboardShortcuts")!
        let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?KeyboardShortcuts")!
        if !NSWorkspace.shared.open(specific) { NSWorkspace.shared.open(fallback) }
    }
}
