import Carbon
import Foundation

/// Which store a row's binding is written back to. The row view never knows;
/// `SettingsModel.apply(_:to:)` below is the only place that maps kind → method,
/// and every one of those methods already calls `onShortcutsChanged?()`.
enum BindableActionKind: String, Sendable, Hashable, CaseIterable {
    /// A fixed `ShortcutAction` — `shortcut.<rawValue>` in UserDefaults.
    case prosper
    /// An extension's `[[contributes.keybindings]]` default — the override map.
    case manifest
    /// One extension command (optionally one of its listed items) — `shortcut.extensions`.
    case extensionItem
    /// Opens the runner already scoped to a prefix — `shortcut.custom`.
    case runnerPrefix
    /// Launches or focuses one app — `shortcut.apps`.
    case app

    /// Fallback for the row's "kind" column when nothing better is derivable.
    var label: String {
        switch self {
        case .prosper: return "Prosper"
        case .manifest, .extensionItem: return "Extension"
        case .runnerPrefix: return "Runner"
        case .app: return "App"
        }
    }
}

/// One bindable thing, whatever store it actually lives in. The Shortcuts pane is
/// a table of these and nothing else: `icon · title · category · recorder · reset ·
/// clear`, with an optional conflict sub-line.
///
/// Built by `ShortcutCatalog.build` from plain arrays — no SwiftUI, no MainActor
/// stores — so the whole merge is unit-testable without a window.
struct BindableAction: Identifiable, Hashable, Sendable {
    let kind: BindableActionKind
    /// Unique within `kind`: an action rawValue, a command id (+ item), a runner
    /// prefix, or a stored record's UUID string.
    let key: String
    /// What the row reads as: "Open Command Runner", "Displays", "DBeaver".
    let title: String
    /// The "kind" column: "Prosper", "Window", "System Settings", "App".
    let category: String
    /// Label to persist when this row first creates a stored record, so a binding
    /// whose extension is later disabled keeps the name it was given.
    let storageLabel: String
    /// App rows only: the stored bundle id / path, so the row's app picker can mark
    /// the current choice. Empty everywhere else.
    let target: String
    let icon: String
    let combo: KeyCombo
    /// Non-nil when ↩ can restore a built-in or manifest default.
    let defaultCombo: KeyCombo?
    /// The stored record behind this row, when one exists. Nil means the row is
    /// offered but unbound — recording on it creates the record.
    let recordID: UUID?
    /// Set when another bound row shares this chord and/or the chord is one macOS
    /// commonly assigns to Spotlight — nil means no hint to show.
    let conflictNote: String?
    /// Folded title + category + combo display, precomputed so filtering a long
    /// list on every keystroke stays a substring scan over an in-memory array.
    let searchText: String

    var id: String { kind.rawValue + "\u{1}" + key }
    /// Registration skips a combo with no modifier, so that is what "unbound" means.
    var isBound: Bool { combo.carbonModifiers != 0 }
    /// A row that exists only because the user made it: ✕ deletes the record
    /// rather than storing an explicit "off".
    var isUserCreated: Bool {
        switch kind {
        case .extensionItem, .runnerPrefix, .app: return true
        case .prosper, .manifest: return false
        }
    }

    init(kind: BindableActionKind, key: String, title: String, category: String,
         storageLabel: String? = nil, target: String = "", icon: String, combo: KeyCombo,
         defaultCombo: KeyCombo? = nil, recordID: UUID? = nil, conflictNote: String? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.category = category
        self.storageLabel = storageLabel ?? title
        self.target = target
        self.icon = icon
        self.combo = combo
        self.defaultCombo = defaultCombo
        self.recordID = recordID
        self.conflictNote = conflictNote
        self.searchText = SettingsSearch.fold("\(title) \(category) \(combo.label)")
    }

    /// Same row with a freshly computed conflict hint. `ShortcutCatalog.build`'s
    /// second pass needs every row assembled before it can see which chords
    /// collide, so the note is stamped on afterward rather than threaded through
    /// each source's own construction.
    func withConflictNote(_ note: String?) -> BindableAction {
        BindableAction(kind: kind, key: key, title: title, category: category,
                       storageLabel: storageLabel, target: target, icon: icon, combo: combo,
                       defaultCombo: defaultCombo, recordID: recordID, conflictNote: note)
    }
}

/// Merges every shortcut source into one list, and filters it. Both pure.
enum ShortcutCatalog {

    /// `\u{1}` joins a command id to an item title in `BindableExtensionAction.id`;
    /// the same split recovers them when a row is written back.
    static func splitExtensionKey(_ key: String) -> (commandID: String, item: String) {
        let parts = key.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
    }

    /// Splits "Quick Toggles › Toggle Dark Mode" into its category and its title.
    /// `extensionCommandLabel` builds exactly this shape (and collapses it to one
    /// component when both halves match), so this is its inverse, not a guess.
    private static func splitLabel(_ label: String, fallback: String) -> (category: String, title: String) {
        guard let range = label.range(of: " \u{203A} ") else { return (fallback, label) }
        return (String(label[label.startIndex..<range.lowerBound]),
                String(label[range.upperBound...]))
    }

    /// Everything bindable right now, in a stable order: Prosper actions in their
    /// declared order, then manifest keybindings, extension commands, runner
    /// prefixes and app shortcuts. The pane splits the result into BOUND / ALL
    /// ACTIONS; it never re-sorts, so a row does not jump while you are on it.
    ///
    /// Every argument is a plain array the caller already has. In particular
    /// `extensionActions` is whatever `ExtensionShortcuts.bindableActions` returned
    /// — pass `[]` on first paint and the merge again when it arrives.
    ///
    /// `spotlightChords` is chord-normalised (`KeyCombo.chord`, display ignored) and
    /// deliberately NOT computed in here: whether ⌘Space actually collides depends
    /// on THIS Mac's live `AppleSymbolicHotKeys`, which would make `build` do I/O
    /// and stop being testable without a window. The caller reads
    /// `SpotlightShortcutConflict.spotlightUsesCommandSpace()` once and passes the
    /// (possibly empty) result in; `[]` means no Spotlight hint anywhere.
    static func build(
        prosperActions: [ShortcutAction],
        combos: [ShortcutAction: KeyCombo],
        manifestKeybindings: [ExtensionShortcuts.ManifestKeybinding] = [],
        keybindingOverrides: [String: KeyCombo] = [:],
        extensionActions: [BindableExtensionAction] = [],
        extensionShortcuts: [ExtensionShortcut] = [],
        activationTargets: [ActivationTarget] = [],
        customShortcuts: [CustomShortcut] = [],
        appShortcuts: [AppShortcut] = [],
        spotlightChords: Set<KeyCombo> = []
    ) -> [BindableAction] {
        var out: [BindableAction] = []
        out.reserveCapacity(prosperActions.count + manifestKeybindings.count
            + extensionActions.count + activationTargets.count + appShortcuts.count)

        for action in prosperActions {
            let (category, title) = splitLabel(action.title, fallback: "Prosper")
            out.append(BindableAction(
                kind: .prosper, key: action.rawValue, title: title,
                category: category, storageLabel: action.title, icon: action.catalogIcon,
                combo: combos[action] ?? action.defaultCombo,
                defaultCombo: action.defaultCombo))
        }

        for kb in manifestKeybindings {
            let (category, title) = splitLabel(kb.label, fallback: BindableActionKind.manifest.label)
            out.append(BindableAction(
                kind: .manifest, key: kb.commandID, title: title, category: category,
                storageLabel: kb.label, icon: "puzzlepiece.extension",
                combo: keybindingOverrides[kb.commandID] ?? kb.defaultCombo,
                defaultCombo: kb.defaultCombo))
        }

        // A saved binding whose action the registry no longer offers (extension
        // disabled, item gone) still gets a row — dropping it would hide a live
        // hotkey and let the next edit overwrite it.
        var savedByKey: [String: ExtensionShortcut] = [:]
        for sc in extensionShortcuts where !sc.commandID.isEmpty {
            savedByKey[sc.commandID + "\u{1}" + sc.item] = sc
        }
        var offered = extensionActions
        let offeredKeys = Set(offered.map(\.id))
        for sc in extensionShortcuts where !sc.commandID.isEmpty
            && !offeredKeys.contains(sc.commandID + "\u{1}" + sc.item) {
            offered.append(BindableExtensionAction(saved: sc))
        }
        for action in offered {
            let saved = savedByKey[action.id]
            let (category, title) = splitLabel(action.label,
                                               fallback: BindableActionKind.extensionItem.label)
            out.append(BindableAction(
                kind: .extensionItem, key: action.id, title: title, category: category,
                storageLabel: action.label, icon: action.icon,
                combo: saved?.combo ?? unsetKeyCombo, recordID: saved?.id))
        }

        // Every activation target is a row, bound or not: that is what replaces
        // both the "Add Shortcut" + dropdown dance and the read-only Extension
        // Activators guide. A saved shortcut for a prefix no target offers any
        // more (a renamed quickdir) keeps its own row.
        var savedByPrefix: [String: CustomShortcut] = [:]
        for cs in customShortcuts where savedByPrefix[cs.prefix] == nil { savedByPrefix[cs.prefix] = cs }
        var targets = activationTargets
        let targetPrefixes = Set(targets.map(\.prefix))
        for cs in customShortcuts where !targetPrefixes.contains(cs.prefix) {
            targets.append(ActivationTarget(label: cs.label, prefix: cs.prefix))
        }
        for target in targets {
            let saved = savedByPrefix[target.prefix]
            out.append(BindableAction(
                kind: .runnerPrefix, key: target.prefix, title: target.label,
                category: "Runner", icon: "text.and.command.macwindow",
                combo: saved?.combo ?? unsetKeyCombo, recordID: saved?.id))
        }

        // Apps are the one source that cannot be enumerated as rows (hundreds
        // installed), so these come only from what the user bound — the footer's
        // app picker is how a new one appears.
        for sc in appShortcuts {
            let name = sc.name.isEmpty ? sc.target : sc.name
            out.append(BindableAction(
                kind: .app, key: sc.id.uuidString,
                title: name.isEmpty ? "Choose App\u{2026}" : name,
                category: "App", target: sc.target, icon: "app", combo: sc.combo,
                recordID: sc.id))
        }

        // Second pass: every row now exists, so chord collisions can be scanned
        // across ALL sources at once (an app shortcut vs. a manifest default vs. a
        // runner prefix — not just app-vs-app like the old check). Cheap to skip
        // when nothing is flagged, which is the common case.
        let duplicateNotes = conflicts(in: out)
        if !duplicateNotes.isEmpty || !spotlightChords.isEmpty {
            out = out.map { row in
                var parts: [String] = []
                if let others = duplicateNotes[row.id] {
                    parts.append("Also used by \(others.joined(separator: ", ")) \u{2014} only one will fire.")
                }
                if row.isBound && spotlightChords.contains(row.combo.chord) {
                    parts.append(SpotlightShortcutConflict.catalogHint)
                }
                guard !parts.isEmpty else { return row }
                return row.withConflictNote(parts.joined(separator: " "))
            }
        }

        return out
    }

    /// Ids of every BOUND row whose chord is shared with at least one other bound
    /// row, mapped to the titles of those other rows — regardless of source, so an
    /// app shortcut and a runner prefix on the same chord flag each other just like
    /// two app shortcuts always did. Unbound rows (`unsetKeyCombo`) never conflict:
    /// they're excluded before grouping starts. One dictionary pass, O(n).
    static func conflicts(in rows: [BindableAction]) -> [String: [String]] {
        var byChord: [KeyCombo: [BindableAction]] = [:]
        for row in rows where row.isBound {
            byChord[row.combo.chord, default: []].append(row)
        }
        var notes: [String: [String]] = [:]
        for group in byChord.values where group.count > 1 {
            for row in group {
                notes[row.id] = group.filter { $0.id != row.id }.map(\.title)
            }
        }
        return notes
    }

    /// Substring match over the precomputed folded text, plus the "Bound only"
    /// filter. One pass, no allocation per row.
    static func filter(_ rows: [BindableAction], query: String, boundOnly: Bool = false)
        -> [BindableAction] {
        let needle = SettingsSearch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if needle.isEmpty && !boundOnly { return rows }
        return rows.filter {
            (!boundOnly || $0.isBound) && (needle.isEmpty || $0.searchText.contains(needle))
        }
    }
}

extension ShortcutAction {
    /// Glyph for the catalog row. Lives here rather than on the action itself so
    /// `Shortcuts.swift` stays the value layer.
    var catalogIcon: String {
        switch self {
        case .runner, .runnerSpace, .runnerBackslash: return "magnifyingglass"
        case .translate: return "character.book.closed"
        case .settings: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .agent: return "brain"
        case .toggleAutocomplete: return "text.cursor"
        case .windowLeftHalf, .windowRightHalf, .windowTopHalf, .windowBottomHalf,
             .windowMaximize, .windowCenter: return "macwindow"
        case .menuBarToggleHidden: return "menubar.rectangle"
        case .calendarTogglePopup: return "calendar"
        case .mixerCycleOutput: return "speaker.wave.2"
        case .mixerToggleMicMute: return "mic.slash"
        case .copyScreenText: return "text.viewfinder"
        case .pickColor: return "eyedropper"
        }
    }
}

// MARK: - Write-back

/// Maps a catalog row onto the `SettingsModel` method that owns its store. Every
/// one of those persists and then calls `onShortcutsChanged?()`, which is what
/// re-runs `AppDelegate.registerHotKeys` — a row writing `ShortcutStore` directly
/// would leave the Carbon registration stale until relaunch.
@MainActor
extension SettingsModel {
    /// Records a combo on a row, creating the stored record if the row is one the
    /// catalog merely offered (an extension action or a runner prefix nobody has
    /// bound yet).
    func bind(_ combo: KeyCombo, to row: BindableAction) {
        switch row.kind {
        case .prosper:
            guard let action = ShortcutAction(rawValue: row.key) else { return }
            setShortcut(combo, for: action)
        case .manifest:
            setExtensionKeybinding(combo, for: row.key)
        case .extensionItem:
            if let id = row.recordID {
                updateExtensionShortcutCombo(id: id, combo: combo)
            } else {
                let (commandID, item) = ShortcutCatalog.splitExtensionKey(row.key)
                addExtensionShortcut(commandID: commandID, item: item,
                                     label: row.storageLabel, combo: combo)
            }
        case .runnerPrefix:
            if let id = row.recordID {
                updateCustomShortcutCombo(id: id, combo: combo)
            } else {
                addCustomShortcut(target: ActivationTarget(label: row.storageLabel,
                                                           prefix: row.key),
                                  combo: combo)
            }
        case .app:
            guard let id = row.recordID else { return }
            updateAppShortcutCombo(id: id, combo: combo)
        }
    }

    /// ↩ — only offered where a default exists.
    func resetBinding(_ row: BindableAction) {
        switch row.kind {
        case .prosper:
            guard let action = ShortcutAction(rawValue: row.key) else { return }
            resetShortcut(action)
        case .manifest:
            // Removing the override is what restores the manifest default.
            setExtensionKeybinding(nil, for: row.key)
        case .extensionItem, .runnerPrefix, .app:
            break
        }
    }

    /// ✕ — a fixed action persists an explicit "off" (removing it would restore the
    /// default); a user-created row is deleted outright.
    func clearBinding(_ row: BindableAction) {
        switch row.kind {
        case .prosper:
            guard let action = ShortcutAction(rawValue: row.key) else { return }
            clearShortcut(action)
        case .manifest:
            setExtensionKeybinding(unsetKeyCombo, for: row.key)
        case .extensionItem:
            if let id = row.recordID { removeExtensionShortcut(id: id) }
        case .runnerPrefix:
            if let id = row.recordID { removeCustomShortcut(id: id) }
        case .app:
            if let id = row.recordID { removeAppShortcut(id: id) }
        }
    }
}
