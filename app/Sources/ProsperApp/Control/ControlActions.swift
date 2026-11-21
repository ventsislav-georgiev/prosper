import AppKit
import Foundation

/// #1818: `actions.list` / `actions.run`, every action the Shortcuts pane and the command runner reach, with no
/// per-action code. The list is ShortcutCatalog.build over the built-ins and ExtensionShortcuts.bindableActions (so a
/// new extension's commands show up by themselves) plus each runner command that takes a query. Ids are the catalog's
/// own (`BindableAction.id`: kind \u{1} key). A run fires the same closure a hotkey press does.
@MainActor
enum ControlActions {
    /// Seam: where actions come from and how they fire. `.app` is the running app's hotkey paths; rows use a recorder.
    @MainActor
    struct Source {
        var registry: () -> ExtensionRegistry?
        /// Runs a built-in's hotkey payload; false when the app holds none for it.
        var fireBuiltIn: (ShortcutAction) -> Bool
        /// An extension action's hotkey press (AppDelegate.pressExtensionAction): `item` is the bound row or the input.
        /// #1850: `done` runs once the handler's invoke has ended (at once when there is no app to fire in).
        var fireExtension: (_ commandID: String, _ item: String, _ done: @escaping @MainActor () -> Void) -> Void

        static var app: Source {
            Source(
                registry: { (NSApp?.delegate as? AppDelegate)?.extensionRegistry },
                fireBuiltIn: { action in
                    guard let payload = (NSApp?.delegate as? AppDelegate)?.builtInPayloads[action] else { return false }
                    payload()
                    return true
                },
                fireExtension: { commandID, item, done in
                    guard let app = NSApp?.delegate as? AppDelegate else { return done() }
                    app.pressExtensionAction(commandID: commandID, item: item, done: done)
                })
        }
    }

    static var source = Source.app

    /// #1850: extension actions an agent ran whose handler has not ended. While above 0, ExtensionViewPanel orders a
    /// window the handler opens (host.window.open) in quietly: no activation, never key. Settable so a row resets it.
    static var agentRunsInFlight = 0

    /// Built-ins an agent must not fire, so they are neither listed nor run here. #1845: the screen readers read
    /// another app's screen through a selection the person makes. #1848: the rest open a Prosper panel or window that
    /// takes the keyboard (DockPolicy.present activates Prosper), so the person's typing in another app would land
    /// in it; the structured control commands cover what they do.
    static let humanOnly: [ShortcutAction] = [
        .copyScreenText, .pickColor,
        .runner, .runnerSpace, .runnerBackslash,
        .translate,
        .settings,
        .clipboard,
        .agent, .agentSessions,
        .agentIsland,
        .calendarTogglePopup,
    ]

    /// #1848: an extension command that opens a Prosper panel that takes the keyboard: its own window
    /// (launches_window, ExtensionShortcuts.toggleWindow) or the runner (quickdirs.run opens it prefilled,
    /// ExtensionShortcuts.nativeFireAction). Neither listed nor run, like humanOnly.
    static func opensPanel(_ command: CommandContribution) -> Bool { command.launchesWindow || command.id == "quickdirs.run" }

    /// The last ExtensionShortcuts.bindableActions result; nil until the first list's refresh ends.
    private(set) static var extensionActions: [BindableExtensionAction]?
    /// The refresh in flight. A control command runs synchronously, and the listing asks each `bindable_items`
    /// command for its rows (async Lua), so a list answers from the last result and refreshes it for the next call.
    /// shortcut: the first list after launch has no listed items yet ("complete": false), drop the cache once a
    /// ControlCommand can await.
    private(set) static var refresh: Task<Void, Never>?

    private static func refreshExtensionActions(_ registry: ExtensionRegistry) {
        guard refresh == nil else { return }
        refresh = Task { @MainActor in
            extensionActions = await ExtensionShortcuts.bindableActions(registry: registry)
            refresh = nil
        }
    }

    /// A runner command the user types a query into (no run-on-select, no window of its own): the input is its query.
    static func takesInput(_ command: CommandContribution) -> Bool { !(command.runsOnSelect || command.launchesWindow) }

    /// {"complete": Bool, "actions": [{id, title, category, icon, takesInput, items?}]}, filtered like the Shortcuts pane.
    static func list(query: String) -> ControlJSON {
        let registry = source.registry()
        if let registry { refreshExtensionActions(registry) }
        let cached = (extensionActions ?? []).filter { action in
            registry?.command(id: action.commandID).map { opensPanel($0.command) } != true
        }
        var rows = ShortcutCatalog.build(
            prosperActions: ShortcutAction.allCases.filter { !humanOnly.contains($0) && $0.isAvailable(registry: registry) },
            combos: [:], extensionActions: cached)
        var inputIDs = Set<String>()
        for record in registry?.records ?? [] where record.isLive {
            for command in record.manifest.contributes?.allCommands ?? []
            where takesInput(command) && !opensPanel(command) && !ExtensionRegistry.dedicatedCommandIDs.contains(command.id) {
                let row = BindableAction(kind: .extensionItem, key: command.id + "\u{1}", title: command.title,
                                         category: record.manifest.extension.title,
                                         icon: command.icon ?? "puzzlepiece.extension", combo: unsetKeyCombo)
                rows.append(row)
                inputIDs.insert(row.id)
            }
        }
        let items = Dictionary(grouping: cached.filter { !$0.item.isEmpty }, by: \.commandID)
        return .object([
            "complete": .bool(extensionActions != nil),
            "actions": .array(ShortcutCatalog.filter(rows, query: query).map { row in
                let input = inputIDs.contains(row.id)
                var o: [String: ControlJSON] = ["id": .string(row.id), "title": .string(row.title),
                                                "category": .string(row.category), "icon": .string(row.icon),
                                                "takesInput": .bool(input)]
                if input, let listed = items[ShortcutCatalog.splitExtensionKey(row.key).commandID] {
                    o["items"] = .array(listed.map { .string($0.item) })
                }
                return .object(o)
            }),
        ])
    }

    /// Fires action `id` through its hotkey path and returns the label the notice shows. Throws for an id no list
    /// would give (unknown kind, built-in or command, or a disabled extension) and for input to an action without it.
    /// shortcut: a listed item is not checked against its command's rows (that is an async listing); like a stale
    /// hotkey, firing a gone item does nothing.
    static func run(id: String, input: String?) throws -> String {
        let unknown = ControlError("unknown action: \(id) (actions.list gives the ids)")
        let (kind, key) = ShortcutCatalog.splitExtensionKey(id)   // the same \u{1} split, kind first
        switch BindableActionKind(rawValue: kind) {
        case .prosper?:
            guard let action = ShortcutAction(rawValue: key) else { throw unknown }
            // #1848: refused ahead of availability, so a human-only id reads the same with its extension off.
            guard !humanOnly.contains(action) else {
                let why = action == .copyScreenText || action == .pickColor
                    ? "it reads the screen through a selection the person makes" : "it opens a panel that takes the keyboard"
                throw ControlError("\(action.title) is human-only: \(why)")
            }
            guard action.isAvailable(registry: source.registry()) else { throw unknown }
            guard input == nil else { throw ControlError("\(action.title) takes no input") }
            guard source.fireBuiltIn(action) else { throw ControlError("\(action.title) is not available right now") }
            return action.title
        case .extensionItem?:
            let (commandID, item) = ShortcutCatalog.splitExtensionKey(key)
            guard let hit = source.registry()?.command(id: commandID), hit.record.isLive,
                  !ExtensionRegistry.dedicatedCommandIDs.contains(commandID) else { throw unknown }
            let takes = item.isEmpty && takesInput(hit.command)
            let label = BindableExtensionAction(commandID: commandID, item: takes ? input ?? "" : item,
                                                extensionTitle: hit.record.manifest.extension.title,
                                                commandTitle: hit.command.title, icon: "").label
            guard !opensPanel(hit.command) else { throw ControlError("\(label) is human-only: it opens a panel that takes the keyboard") }
            guard input == nil || takes else { throw ControlError("\(label) takes no input") }
            agentRunsInFlight += 1
            source.fireExtension(commandID, takes ? input ?? "" : item) { agentRunsInFlight -= 1 }
            return label
        default:
            throw unknown
        }
    }
}

extension ControlRegistry {
    /// #1818: wired with `ControlRegistry.registerActions(&r)` in `standard()`.
    static func registerActions(_ r: inout ControlRegistry) {
        r.register(ControlCommand(
            name: "actions.list",
            summary: "Every action the command runner and Settings > Shortcuts reach (built-ins and every extension command), with its id for actions.run.",
            args: ["query": ControlArg(type: "string", summary: "Keep only actions whose title or category contains this text.")],
            mutates: false) { _, args in
            guard case .string(let q)? = args["query"] else { return ControlActions.list(query: "") }
            return ControlActions.list(query: q)
        })
        r.register(.change(
            name: "actions.run",
            summary: "Run an action by its actions.list id, exactly as its shortcut would.",
            args: ["id": ControlArg(type: "string", required: true, summary: "The id from actions.list."),
                   "input": ControlArg(type: "string", summary: "The query for an action whose takesInput is true.")]) { _, args in
            guard case .string(let id)? = args["id"] else { throw ControlError("missing argument 'id' for actions.run") }
            var input: String?
            if case .string(let s)? = args["input"] { input = s }
            let label = try ControlActions.run(id: id, input: input)
            // An action has no known inverse: no undo, so no Undo button; the notice reads "Agent ran: <label>".
            return ControlChange(summary: label, verb: "ran", undo: nil)
        })
    }
}
