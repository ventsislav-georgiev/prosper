import AppKit
import Carbon
import Foundation

/// A rebindable key combination: a virtual key code plus a Carbon modifier mask
/// (kVK_* / cmdKey|optionKey|controlKey|shiftKey), with a cached display string.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String
}

/// A user-defined global shortcut that opens the command runner pre-seeded with
/// a given activation `prefix`, so pressing it jumps straight into a command /
/// extension without typing its prefix (e.g. prefix "o " → open-app; ">" →
/// shell). An empty prefix opens the runner blank. `label` is shown in Settings.
struct CustomShortcut: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var combo: KeyCombo
    var prefix: String
    var label: String

    init(id: UUID = UUID(), combo: KeyCombo, prefix: String, label: String) {
        self.id = id
        self.combo = combo
        self.prefix = prefix
        self.label = label
    }
}

/// A pickable target the user can bind a custom shortcut to. The `prefix` is the
/// exact runner-input prefix that routes to it (see `CommandRouter`). Built-in
/// targets are listed here; migrated Lua extensions can contribute more later.
struct ActivationTarget: Identifiable, Sendable, Equatable, Hashable {
    var label: String
    var prefix: String
    var id: String { label }

    static let builtins: [ActivationTarget] = [
        ActivationTarget(label: "Open App", prefix: "o "),
        ActivationTarget(label: "Run Shell Command", prefix: "> "),
        ActivationTarget(label: "Quicklinks", prefix: "ql "),
        ActivationTarget(label: "Emoji Picker", prefix: ":"),
        ActivationTarget(label: "Blank Runner", prefix: ""),
    ]

    /// Every bindable target: a blank runner plus one entry per runner-mode trigger
    /// contributed by an enabled extension (manifest `prefix` + dynamic quickdir
    /// triggers — see `ExtensionRegistry.modeTriggers`). So binding a shortcut to
    /// "Bookmarks", "Translate", a quickdir, etc. works out of the box for any
    /// extension that offers a trigger, with no host edits. Built-ins not covered
    /// by a trigger (e.g. Emoji) are appended so nothing regresses.
    @MainActor
    static func allTargets(registry: ExtensionRegistry?) -> [ActivationTarget] {
        var out: [ActivationTarget] = [ActivationTarget(label: "Blank Runner", prefix: "")]
        var seenPrefix: Set<String> = [""]
        var seenCommand: Set<String> = []

        // One entry per command, not per prefix: a command that registers several
        // prefixes (e.g. Translate's "l "/"t ") would otherwise show up multiple
        // times under the same label. modeTriggers() is longest-prefix-first, so
        // the canonical (most specific) prefix is the one kept.
        var triggers: [(label: String, prefix: String, ext: String)] = []
        for t in registry?.modeTriggers() ?? [] where !t.prefix.isEmpty {
            guard seenCommand.insert(t.commandID).inserted,
                  seenPrefix.insert(t.prefix).inserted else { continue }
            triggers.append((t.title, t.prefix, t.extensionTitle))
        }
        // Disambiguate genuinely distinct commands that share a title (several
        // "Run Shell" commands from different extensions) by appending the
        // contributing extension's name, so the picker text says which is which.
        let titleCounts = triggers.reduce(into: [String: Int]()) { $0[$1.label, default: 0] += 1 }
        for tr in triggers {
            let label = (titleCounts[tr.label] ?? 0) > 1 && !tr.ext.isEmpty
                ? "\(tr.label) · \(tr.ext)" : tr.label
            out.append(ActivationTarget(label: label, prefix: tr.prefix))
        }
        for b in builtins where seenPrefix.insert(b.prefix).inserted { out.append(b) }
        return out
    }
}

/// A combo that is recorded but intentionally empty — the action is disabled
/// until the user records a key for it. Registration skips any combo with no
/// modifier, so an unset combo never fires.
let unsetKeyCombo = KeyCombo(keyCode: 0, carbonModifiers: 0, display: "Unset")

extension KeyCombo {
    /// Parse a manifest keybinding string ("cmd+alt+ctrl+l", "shift+f5",
    /// "cmd+space") into a KeyCombo. nil on an unknown key token. Modifier aliases:
    /// cmd/command/⌘, alt/opt/option/⌥, ctrl/control/⌃, shift/⇧. Powers
    /// `[[contributes.keybindings]]` (host API plan §C).
    static func parse(_ string: String) -> KeyCombo? {
        let tokens = string.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var mods: UInt32 = 0
        var keyToken: String?
        for t in tokens {
            switch t {
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: keyToken = t // last non-modifier token is the key
            }
        }
        guard let keyToken, let code = keyCode(forName: keyToken) else { return nil }
        return KeyCombo(keyCode: code, carbonModifiers: mods, display: string)
    }

    /// Key-name → virtual keycode for the common keys a keybinding uses.
    private static func keyCode(forName name: String) -> UInt32? {
        Self.keyCodeTable[name].map(UInt32.init)
    }

    /// A canonical, re-parseable spec ("cmd+alt+q") built from the keyCode + modifier
    /// mask — the inverse of `parse`. `display` is for humans (⌘Q) and is NOT
    /// re-parseable, so the shortcut store serializes via this instead. Returns nil
    /// for an unset/unknown key (so a half-recorded combo isn't stored as a rule).
    var specString: String? {
        guard let name = Self.codeToName[Int(keyCode)] else { return nil }
        var parts: [String] = []
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("alt") }
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        parts.append(name)
        return parts.joined(separator: "+")
    }

    private static let codeToName: [Int: String] =
        Dictionary(keyCodeTable.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    /// Single printable ASCII char for a virtual keycode (layout-independent), or nil
    /// for keys with no character (space, arrows, F-keys, return…). Lets a synthetic
    /// key event be stamped with the char a menu key-equivalent matches on, so e.g. ⌘W
    /// closes a window even under a non-Latin layout. See KeyInjector.stroke.
    static func asciiChar(forKeyCode code: UInt32) -> String? {
        guard let name = codeToName[Int(code)], name.count == 1 else { return nil }
        return name
    }

    /// Menu key-equivalent for this combo: the printable char NSMenuItem matches/
    /// displays. nil for an unset combo or a key with no single char (so the caller
    /// clears the equivalent rather than show a bogus one). Space maps to " " so the
    /// menu renders it; AppKit shows it as the ␣ glyph.
    var menuKeyEquivalent: String? {
        guard self != unsetKeyCombo else { return nil }
        if keyCode == UInt32(kVK_Space) { return " " }
        return KeyCombo.asciiChar(forKeyCode: keyCode)
    }

    /// Carbon modifier mask translated to AppKit flags for `keyEquivalentModifierMask`.
    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        return mask
    }

    private static let keyCodeTable: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14,
        "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
        "f19": kVK_F19, "f20": kVK_F20,
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
        "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave,
    ]
}

/// The user-rebindable global actions. Every trigger here — including the two
/// runner triggers that open the universal launcher (⌥Space, ⌥\\) — is
/// rebindable and can be cleared from Settings, so none are hard-wired anymore.
enum ShortcutAction: String, CaseIterable, Sendable {
    case runner
    case runnerSpace
    case runnerBackslash
    case translate
    case settings
    case clipboard
    case agent
    case toggleAutocomplete
    case windowLeftHalf
    case windowRightHalf
    case windowTopHalf
    case windowBottomHalf
    case windowMaximize
    case windowCenter
    case menuBarToggleHidden

    var title: String {
        switch self {
        case .runner: return "Open Command Runner"
        case .runnerSpace: return "Open Command Runner (alt 1)"
        case .runnerBackslash: return "Open Command Runner (alt 2)"
        case .translate: return "Open Translate"
        case .settings: return "Open Settings"
        case .clipboard: return "Open Clipboard History"
        case .agent: return "Open Coding Agent"
        case .toggleAutocomplete: return "Toggle Inline Autocomplete"
        case .windowLeftHalf: return "Window: Left Half"
        case .windowRightHalf: return "Window: Right Half"
        case .windowTopHalf: return "Window: Top Half"
        case .windowBottomHalf: return "Window: Bottom Half"
        case .windowMaximize: return "Window: Maximize"
        case .windowCenter: return "Window: Center"
        case .menuBarToggleHidden: return "Menu Bar: Reveal/Hide Section"
        }
    }

    /// Stable Carbon hot-key id used when (re)registering.
    var hotKeyId: UInt32 {
        switch self {
        case .runner: return 1
        case .runnerSpace: return 2
        case .runnerBackslash: return 3
        case .clipboard: return 4
        case .agent: return 5
        case .windowLeftHalf: return 6
        case .windowRightHalf: return 7
        case .windowMaximize: return 8
        case .windowCenter: return 9
        case .windowTopHalf: return 10
        case .windowBottomHalf: return 11
        case .settings: return 12
        case .translate: return 13
        case .toggleAutocomplete: return 14
        case .menuBarToggleHidden: return 15
        }
    }

    /// The extension that owns this fixed shortcut, if any. When that extension is
    /// disabled the shortcut is neither registered nor shown in Settings — so an
    /// extension-provided trigger comes and goes with the extension instead of
    /// lingering as a dead hardcoded binding. Translate is a Lua system extension
    /// (com.prosper.translate); its ⌥L opens that extension's runner mode.
    var owningExtensionID: String? {
        switch self {
        case .translate: return "com.prosper.translate"
        case .menuBarToggleHidden: return "com.prosper.menubar"
        default: return nil
        }
    }

    /// False only when this shortcut belongs to an extension that's currently
    /// disabled. Used to gate both global registration and the Settings listing.
    @MainActor
    func isAvailable(registry: ExtensionRegistry?) -> Bool {
        guard let ext = owningExtensionID else { return true }
        return registry?.record(id: ext)?.enabled ?? false
    }

    /// Window-management actions; grouped so the Settings UI can list them apart
    /// from the app/launcher shortcuts.
    var isWindowManagement: Bool {
        switch self {
        case .windowLeftHalf, .windowRightHalf, .windowTopHalf, .windowBottomHalf,
             .windowMaximize, .windowCenter:
            return true
        default:
            return false
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .runner:
            return KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey), display: "⌘Space")
        case .runnerSpace:
            return KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), display: "⌥Space")
        case .runnerBackslash:
            // No default — a spare alt slot the user can bind if they want a third.
            return unsetKeyCombo
        case .translate:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(optionKey), display: "⌥L")
        case .settings:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_Backslash), carbonModifiers: UInt32(optionKey), display: "⌥\\")
        case .clipboard:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | shiftKey), display: "⇧⌥A")
        case .agent:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(optionKey), display: "⌥G")
        case .toggleAutocomplete:
            // Opt-in: no default combo, so it never collides out of the box.
            return unsetKeyCombo
        case .windowLeftHalf:
            return KeyCombo(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥←")
        case .windowRightHalf:
            return KeyCombo(keyCode: UInt32(kVK_RightArrow), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥→")
        case .windowTopHalf:
            return KeyCombo(keyCode: UInt32(kVK_UpArrow), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥↑")
        case .windowBottomHalf:
            return KeyCombo(keyCode: UInt32(kVK_DownArrow), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥↓")
        case .windowMaximize:
            return KeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥↩")
        case .windowCenter:
            return KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥C")
        case .menuBarToggleHidden:
            // Opt-in: no default combo so it never collides out of the box. The
            // chevron in the menu bar is the always-available trigger.
            return unsetKeyCombo
        }
    }
}

/// Persists per-action key combos in UserDefaults (JSON), falling back to the
/// built-in defaults. Pure value layer — registration lives in AppDelegate.
enum ShortcutStore {
    private static var defaults: UserDefaults { UserDefaults.standard }
    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }

    static func combo(for action: ShortcutAction) -> KeyCombo {
        guard let data = defaults.data(forKey: key(action)),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else {
            return action.defaultCombo
        }
        return combo
    }

    static func setCombo(_ combo: KeyCombo, for action: ShortcutAction) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: key(action))
    }

    static func reset(_ action: ShortcutAction) {
        defaults.removeObject(forKey: key(action))
    }

    // MARK: - User-defined custom shortcuts

    private static let customKey = "shortcut.custom"

    /// All user-defined custom shortcuts (empty by default).
    static func customShortcuts() -> [CustomShortcut] {
        guard let data = defaults.data(forKey: customKey),
              let list = try? JSONDecoder().decode([CustomShortcut].self, from: data) else {
            return []
        }
        return list
    }

    static func setCustomShortcuts(_ list: [CustomShortcut]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: customKey)
    }
}
