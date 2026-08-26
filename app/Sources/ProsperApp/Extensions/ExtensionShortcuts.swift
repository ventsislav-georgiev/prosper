import AppKit
import Foundation

/// "Extension › Command", collapsed to just the shared title when both halves
/// are identical (pasteplain: extension title and its one command are both
/// "Paste as Plain Text") — otherwise the row reads as "Paste as Plain Text ›
/// Paste as Plain Text".
private func extensionCommandLabel(_ extensionTitle: String, _ commandTitle: String) -> String {
    extensionTitle == commandTitle ? extensionTitle : "\(extensionTitle) \u{203A} \(commandTitle)"
}

/// A global hotkey the user bound to ONE extension command, fired directly: no
/// launcher, nothing to type (⌃⌥D → Toggle Dark Mode, ⌃⌥P → System Settings ›
/// Displays). Unlike `CustomShortcut`, which opens the runner pre-seeded with an
/// activation prefix, this runs the command and is done.
///
/// A parameterless command (`runs_on_select` / `launches_window`) stores an empty
/// `item`. A command that lists its own targets (`bindable_items`) stores the
/// chosen row's title, which is both the argument handed to the Lua handler and
/// the row picked back out of its result.
struct ExtensionShortcut: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var commandID: String
    var item: String
    var combo: KeyCombo
    /// Display label captured at bind time, so Settings can still name the binding
    /// while its extension is disabled (the action list is empty then).
    var label: String

    init(id: UUID = UUID(), commandID: String, item: String = "",
         combo: KeyCombo, label: String) {
        self.id = id
        self.commandID = commandID
        self.item = item
        self.combo = combo
        self.label = label
    }
}

/// One extension action the user can pick in Settings › Shortcuts.
struct BindableExtensionAction: Identifiable, Hashable, Sendable {
    let commandID: String
    /// Empty for a parameterless command; a listed row's title otherwise.
    let item: String
    /// What the picker and the bound row show: "Quick Toggles › Toggle Dark Mode",
    /// "System Settings › Displays". Stored rather than computed so a binding whose
    /// action is no longer available keeps the name it was given.
    let label: String
    let icon: String

    /// Stable across relaunches (unlike a UUID), so a picker selection survives a
    /// rebuilt action list. `\u{1}` cannot occur in a command id or a row title.
    var id: String { commandID + "\u{1}" + item }

    init(commandID: String, item: String, extensionTitle: String,
         commandTitle: String, icon: String) {
        self.commandID = commandID
        self.item = item
        self.label = extensionCommandLabel(extensionTitle, item.isEmpty ? commandTitle : item)
        self.icon = icon
    }

    /// Rebuilt from a saved binding whose action the registry no longer offers —
    /// its extension is disabled, or the item is gone. Keeps the row selectable and
    /// correctly named instead of letting the picker fall through to a neighbour.
    init(saved: ExtensionShortcut) {
        self.commandID = saved.commandID
        self.item = saved.item
        self.label = saved.label
        self.icon = "puzzlepiece.extension"
    }
}

/// Enumerating and firing extension-contributed shortcut targets. Pure functions
/// over the registry — registration itself stays in `AppDelegate.registerHotKeys`.
enum ExtensionShortcuts {

    // MARK: - What can be bound

    /// Every extension action bindable right now, sorted by label.
    ///
    /// Parameterless commands come straight from the manifests. Commands marked
    /// `bindable_items` are expanded by ASKING each one for its bare listing —
    /// the same call the runner makes when its mode opens — so the 43 System
    /// Settings panes and every saved script become individually bindable with no
    /// per-extension host code and no second manifest table to keep in sync.
    ///
    /// Disabled or untrusted extensions contribute nothing: `isLive` gates the
    /// whole walk, which is what makes a binding disappear from Settings the
    /// moment its extension is turned off.
    @MainActor
    static func bindableActions(registry: ExtensionRegistry) async -> [BindableExtensionAction] {
        var out: [BindableExtensionAction] = []
        var listing: [(command: CommandContribution, ext: String)] = []

        for record in registry.records where record.isLive {
            let ext = record.manifest.extension.title
            for command in record.manifest.contributes?.allCommands ?? []
            where !ExtensionRegistry.dedicatedCommandIDs.contains(command.id) {
                if command.runsOnSelect || command.launchesWindow {
                    out.append(BindableExtensionAction(
                        commandID: command.id, item: "", extensionTitle: ext,
                        commandTitle: command.title,
                        icon: command.icon ?? "puzzlepiece.extension"))
                }
                if command.bindableItems { listing.append((command, ext)) }
            }
        }

        for entry in listing {
            let prefix = entry.command.allPrefixes.first ?? ""
            for title in await itemTitles(commandID: entry.command.id, prefix: prefix,
                                          registry: registry) {
                out.append(BindableExtensionAction(
                    commandID: entry.command.id, item: title, extensionTitle: entry.ext,
                    commandTitle: entry.command.title,
                    icon: entry.command.icon ?? "puzzlepiece.extension"))
            }
        }

        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Row titles a listing command returns for a bare prefix (its `list_on_empty`
    /// listing). Empty when the command declines, returns a plain string, or
    /// renders anything other than a list — all of which just mean "nothing to
    /// enumerate", never an error worth surfacing.
    @MainActor
    static func itemTitles(commandID: String, prefix: String,
                           registry: ExtensionRegistry) async -> [String] {
        guard let json = await registry.invokeAsync(commandID: commandID, query: prefix),
              let node = try? ExtensionViewNode.decode(json: json),
              case .list(let list) = node
        else { return [] }
        return list.items.map(\.title)
    }

    /// An extension-declared default keybinding (`[[contributes.keybindings]]`) of
    /// a live extension, resolved to something Settings can show and rebind.
    /// These used to register invisibly — declared in a manifest, claimed at
    /// launch, listed nowhere.
    struct ManifestKeybinding: Identifiable, Hashable, Sendable {
        let commandID: String
        let extensionTitle: String
        let commandTitle: String
        let defaultCombo: KeyCombo
        var id: String { commandID }
        var label: String { extensionCommandLabel(extensionTitle, commandTitle) }
    }

    @MainActor
    static func manifestKeybindings(registry: ExtensionRegistry) -> [ManifestKeybinding] {
        var out: [ManifestKeybinding] = []
        for record in registry.records where record.isLive {
            let ext = record.manifest.extension.title
            for kb in record.manifest.contributes?.allKeybindings ?? [] {
                // An unparseable key never registered and can't be reset to, so it
                // has nothing to show; the user can still bind the command below.
                guard let combo = KeyCombo.parse(kb.key) else { continue }
                let title = record.manifest.contributes?.allCommands
                    .first { $0.id == kb.command }?.title ?? kb.command
                out.append(ManifestKeybinding(commandID: kb.command, extensionTitle: ext,
                                              commandTitle: title, defaultCombo: combo))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    // MARK: - Firing

    /// The query handed to the Lua handler for a binding.
    ///
    /// The runner restores a command's canonical prefix before calling, and every
    /// handler strips it back off, so a bound item reproduces exactly what typing
    /// "ss Displays" would send. A parameterless binding keeps the empty query the
    /// manifest keybindings have always been invoked with — those commands take no
    /// argument, and openlid's handlers read a prefix as input they must parse.
    @MainActor
    static func query(commandID: String, item: String, registry: ExtensionRegistry) -> String {
        guard !item.isEmpty else { return "" }
        return (registry.command(id: commandID)?.command.allPrefixes.first ?? "") + item
    }

    /// Runs a bound extension action with no UI.
    ///
    /// Two shapes exist and both are handled by the same call. A command that ACTS
    /// (a toggle, a saved script) has already done its work by the time the
    /// handler returns — its result is a status line or an output listing with
    /// nothing left to activate. A command that OFFERS (System Settings) returns a
    /// list of targets, so the row the user bound is picked back out by title and
    /// its own activation is performed: open its `url`, open its `launch` path, or
    /// dispatch its first declared action — the same three routes the runner takes
    /// on Enter (`RunnerPanel.activateRow`).
    ///
    /// Silent when nothing resolves. A pane id renamed by a macOS release, or a
    /// script deleted since the binding was made, leaves a shortcut that does
    /// nothing rather than one that does something unexpected.
    @MainActor
    static func fire(commandID: String, item: String, registry: ExtensionRegistry) async {
        let query = query(commandID: commandID, item: item, registry: registry)
        guard let json = await registry.invokeAsync(commandID: commandID, query: query),
              let node = try? ExtensionViewNode.decode(json: json),
              case .list(let list) = node
        else { return }

        // Prefer the exact row the user bound; fall back to the only row a
        // narrowing query could have produced.
        guard let row = list.items.first(where: { $0.title == item }) ?? list.items.first
        else { return }

        if let target = row.url, let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        } else if let path = row.launch {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let action = row.allActions.first {
            _ = await registry.dispatchActionAsync(
                commandID: commandID, actionID: action.id,
                value: action.value ?? row.title, formValues: [:])
        }
    }

    // MARK: - Registration input

    /// One hotkey to claim for an extension command: the manifest keybindings of
    /// every live extension (with the user's override applied) followed by the
    /// user's own bindings. Pure, so `AppDelegate.registerHotKeys` stays a loop
    /// over this and the id range has a single owner.
    ///
    /// Skips anything with no modifier — an unrecorded binding, and a user-cleared
    /// manifest default, both land on `unsetKeyCombo`, and registering a bare key
    /// would swallow ordinary typing.
    struct Registration: Equatable {
        let commandID: String
        let item: String
        let combo: KeyCombo
        /// Human label for the hotkey-conflict notification.
        let label: String
    }

    @MainActor
    static func registrations(registry: ExtensionRegistry,
                              overrides: [String: KeyCombo],
                              userShortcuts: [ExtensionShortcut]) -> [Registration] {
        var out: [Registration] = []
        for record in registry.records where record.isLive {
            for kb in record.manifest.contributes?.allKeybindings ?? [] {
                guard let combo = overrides[kb.command] ?? KeyCombo.parse(kb.key) else { continue }
                guard combo.carbonModifiers != 0 else { continue }
                out.append(Registration(
                    commandID: kb.command, item: "", combo: combo,
                    label: "\(record.manifest.extension.title) \u{00B7} \(combo.display)"))
            }
        }
        let live = Set(registry.records.filter(\.isLive)
            .flatMap { $0.manifest.contributes?.allCommands.map(\.id) ?? [] })
        for sc in userShortcuts where sc.combo.carbonModifiers != 0 && live.contains(sc.commandID) {
            out.append(Registration(commandID: sc.commandID, item: sc.item, combo: sc.combo,
                                    label: "\(sc.label) (\(sc.combo.display))"))
        }
        return out
    }
}
