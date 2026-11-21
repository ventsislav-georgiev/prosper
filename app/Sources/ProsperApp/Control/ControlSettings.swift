import Foundation

/// #1810: one user-facing setting as the control channel sees it. Value and write go through the real store
/// (Preferences, ThemeStore, SettingsHooks), never a copy; `set == nil` means the Settings control has side
/// effects the channel cannot repeat exactly, so the setting is readable here but changed only in Settings.
/// Secrets (Keychain items, tokens, the sync encryption key, ccpool secrets) are never declared here.
struct ControlSetting {
    enum Kind {
        case bool
        case number(ClosedRange<Double>, integer: Bool)
        case choice([String])
    }

    let key: String
    let title: String
    let section: String
    let kind: Kind
    let defaultValue: ControlJSON
    let get: @MainActor () -> ControlJSON
    let set: (@MainActor (ControlJSON) -> Void)?

    var typeName: String {
        switch kind {
        case .bool: "boolean"
        case .number(_, let integer): integer ? "integer" : "number"
        case .choice: "string"
        }
    }

    /// The value in the setting's own form, or an error naming what it accepts.
    func checked(_ v: ControlJSON) throws -> ControlJSON {
        switch (kind, v) {
        case (.bool, .bool): return v
        case (.number(let r, let integer), .number(let n)):
            guard n.isFinite, r.contains(n) else { throw ControlError("\(key) must be between \(r.lowerBound) and \(r.upperBound)") }
            guard !integer || n == n.rounded() else { throw ControlError("\(key) must be a whole number") }
            return v
        case (.choice(let allowed), .string(let s)):
            guard allowed.contains(s) else { throw ControlError("\(key) must be one of \(allowed.joined(separator: ", "))") }
            return v
        default:
            throw ControlError("\(key) must be \(typeName), got \(v.typeName)")
        }
    }

    @MainActor var row: ControlJSON {
        var o: [String: ControlJSON] = [
            "key": .string(key), "title": .string(title), "section": .string(section), "type": .string(typeName),
            "value": get(), "default": defaultValue, "writable": .bool(set != nil),
        ]
        switch kind {
        case .bool: break
        case .number(let r, _): o["min"] = .number(r.lowerBound); o["max"] = .number(r.upperBound)
        case .choice(let allowed): o["allowed"] = .array(allowed.map { .string($0) })
        }
        return .object(o)
    }
}

extension ControlSetting {
    static func bool(_ key: String, _ title: String, _ section: String, _ def: Bool,
                     get: @escaping @MainActor () -> Bool, set: (@MainActor (Bool) -> Void)?) -> ControlSetting {
        var write: (@MainActor (ControlJSON) -> Void)?
        if let set { write = { v in if case .bool(let b) = v { set(b) } } }
        return ControlSetting(key: key, title: title, section: section, kind: .bool, defaultValue: .bool(def),
                              get: { .bool(get()) }, set: write)
    }

    static func number(_ key: String, _ title: String, _ section: String, _ def: Double, _ range: ClosedRange<Double>,
                       integer: Bool = false, get: @escaping @MainActor () -> Double,
                       set: (@MainActor (Double) -> Void)?) -> ControlSetting {
        var write: (@MainActor (ControlJSON) -> Void)?
        if let set { write = { v in if case .number(let n) = v { set(n) } } }
        return ControlSetting(key: key, title: title, section: section, kind: .number(range, integer: integer), defaultValue: .number(def),
                              get: { .number(get()) }, set: write)
    }

    /// Allowed values come from the store's own enum, so a new case shows up here without an edit.
    static func choice<E: RawRepresentable & CaseIterable>(_ key: String, _ title: String, _ section: String, _ def: E,
                                                          get: @escaping @MainActor () -> E,
                                                          set: (@MainActor (E) -> Void)?) -> ControlSetting where E.RawValue == String {
        var write: (@MainActor (ControlJSON) -> Void)?
        if let set { write = { v in if case .string(let r) = v, let e = E(rawValue: r) { set(e) } } }
        return ControlSetting(key: key, title: title, section: section, kind: .choice(E.allCases.map(\.rawValue)),
                              defaultValue: .string(def.rawValue), get: { .string(get().rawValue) }, set: write)
    }
}

/// #1810: settings.schema / settings.get / settings.set over the real stores. Built on demand per call: no
/// observers, no cache, nothing runs while no agent asks.
enum ControlSettings {
    /// Settings pane labels (from `nativeSettingsIndex`) that are not a value this channel exposes, each with why.
    /// ControlSettingsTests fails for a pane control that is neither a schema title nor listed here.
    static let notSettings: [String: String] = [
        "Accessibility": "permission status, granted in System Settings",
        "Screen Recording": "permission status, granted in System Settings",
        "Notifications": "permission status, granted in System Settings",
        "System Audio Recording": "permission status, granted in System Settings",
        "Enabled in System Settings but still not trusted?": "a repair button",
        "Prosper Remote": "a link to the iPhone app",
        "Stored entries": "a count",
        "Status": "account status readout",
        "Status refreshes by": "account status readout",
        "Sign out": "an account action",
        "Delete account": "an account action",
        "Buy me a coffee": "a link",
        "GitHub Sponsors": "a link",
        "Sync my settings across devices": "needs sign-in and the encryption key; changed in Settings only",
        "Encryption key": "secret: never readable",
        "Last sync": "a readout",
        "Last sent": "a readout",
        "Next send": "a readout",
        "Send now": "an action (actions.run)",
        "Mute every microphone": "live device state, not a stored setting (actions.run)",
        "Next sound output": "a shortcut row; the outputs list is device state",
        "Nothing hidden": "an empty-list placeholder",
        "Alert output": "a system device choice, not a Prosper setting",
        "Preferred input": "a device id that exists only while that microphone is attached",
        "Number alignment": "a per-stat layout list, edited in Settings",
        "Let agents control Prosper": "the agent-control switch itself (#1808): a person changes it in Settings",
    ]

    @MainActor static func all() -> [ControlSetting] {
        let hooks = SettingsHooks.shared
        let theme = ThemeStore.shared
        var r: [ControlSetting] = []
        // General
        r.append(contentsOf: [
            .bool("launchAtLogin", "Launch at login", "General", true, get: { Preferences.launchAtLogin }, set: nil),
            .bool("showMenuBarIcon", "Show menu bar icon", "General", true, get: { Preferences.showMenuBarIcon }, set: nil),
            .bool("showDockIcon", "Show Dock icon while a window is open", "General", true, get: { Preferences.showDockIcon }, set: nil),
            .choice("runnerPlacement", "Panel placement", "General", RunnerPlacement.cursorScreen,
                    get: { Preferences.runnerPlacement }, set: { Preferences.runnerPlacement = $0 }),
            .choice("quickSelectModifier", "Quick-select modifier", "General", QuickSelectModifier.command,
                    get: { Preferences.quickSelectModifier }, set: { Preferences.quickSelectModifier = $0 }),
            .bool("clipboardHistoryEnabled", "Enable clipboard history", "General", true,
                  get: { Preferences.clipboardHistoryEnabled }, set: nil),
            .number("clipboardHistoryMaxItems", "History size", "General", 500,
                    Double(Preferences.clipboardHistoryMaxRange.lowerBound)...Double(Preferences.clipboardHistoryMaxRange.upperBound),
                    integer: true, get: { Double(Preferences.clipboardHistoryMaxItems) },
                    set: { Preferences.clipboardHistoryMaxItems = Int($0); hooks.onClipboardMaxItemsChanged?() }),
            .bool("useClipboardContext", "Use clipboard text as completion context", "General", false,
                  get: { Preferences.useClipboardContext }, set: { Preferences.useClipboardContext = $0 }),
            .bool("remoteTerminalEnabled", "Serve sessions over Tailscale", "General", false, get: { Preferences.remoteTerminalEnabled }, set: nil),
            .bool("isolateRemoteSessions", "Isolate sessions", "General", false,
                  get: { Preferences.isolateRemoteSessions }, set: { Preferences.isolateRemoteSessions = $0 }),
            .bool("liveStatusEnabled", "Live status on iPhone", "General", true, get: { Preferences.liveStatusEnabled }, set: nil),
            .bool("clipboardSyncWithPhone", "Sync clipboard history with iPhone", "General", false,
                  get: { Preferences.clipboardSyncWithPhone }, set: { Preferences.clipboardSyncWithPhone = $0 }),
            .bool("runCommandsFromPhone", "Run commands from iPhone", "General", false,
                  get: { Preferences.runCommandsFromPhone }, set: { Preferences.runCommandsFromPhone = $0 }),
            .bool("remoteAllowWhenTailscaleDown", "Allow when Tailscale isn't answering", "General", false,
                  get: { Preferences.remoteAllowWhenTailscaleDown }, set: { Preferences.remoteAllowWhenTailscaleDown = $0 }),
            .bool("autocompleteEnabled", "Inline autocomplete", "General", false,
                  get: { Preferences.autocompleteEnabled }, set: { Preferences.autocompleteEnabled = $0; hooks.onAutocompleteChanged?($0) }),
            .bool("agentEnabled", "Coding agent", "General", false,
                  get: { Preferences.agentEnabled }, set: { Preferences.agentEnabled = $0 }),
        ] as [ControlSetting])
        // Shortcuts
        r.append(contentsOf: [
            .bool("hyperKeyEnabled", "Hold Caps Lock as a hyper key", "Shortcuts", false,
                  get: { Preferences.hyperKeyEnabled }, set: { Preferences.hyperKeyEnabled = $0; hooks.onHyperKeyChanged?($0) }),
            .bool("doubleTapQuitEnabled", "Require a double-tap of \u{2318}Q to quit", "Shortcuts", false,
                  get: { Preferences.doubleTapQuitEnabled }, set: { Preferences.doubleTapQuitEnabled = $0; ShortcutRulesStore.shared.apply() }),
            .bool("finderF2RenameEnabled", "Press F2 to rename the selected file", "Shortcuts", false,
                  get: { Preferences.finderF2RenameEnabled }, set: { Preferences.finderF2RenameEnabled = $0; ShortcutRulesStore.shared.apply() }),
            .bool("finderCutPasteEnabled", "Press \u{2318}X then \u{2318}V to move files", "Shortcuts", false,
                  get: { Preferences.finderCutPasteEnabled }, set: { Preferences.finderCutPasteEnabled = $0; hooks.onFinderCutPasteChanged?($0) }),
            .bool("finderPasteImageEnabled", "Press \u{2318}V to save a copied image as a PNG file", "Shortcuts", false,
                  get: { Preferences.finderPasteImageEnabled }, set: { Preferences.finderPasteImageEnabled = $0; hooks.onFinderCutPasteChanged?($0) }),
        ] as [ControlSetting])
        // Appearance: written through ThemeStore so the live palette follows, read from its persisted value.
        r.append(contentsOf: [
            ControlSetting(key: "theme", title: "Theme", section: "Appearance", kind: .choice(theme.available.map(\.id)),
                           defaultValue: .string(ThemeDescriptor.builtInID), get: { .string(theme.activeID) },
                           set: { if case .string(let id) = $0 { theme.select(id: id) } }),
            .choice("menuBarIconSize", "Menu bar icon size", "Appearance", MenuBarIconSize.medium,
                    get: { Preferences.menuBarIconSize }, set: { theme.setMenuBarIconSize($0) }),
            .number("prosper.uiScale", "UI Size", "Appearance", 1.0, Preferences.uiScaleRange,
                    get: { Preferences.uiScale }, set: { theme.setScale(CGFloat($0)) }),
            .number("prosper.uiOpacity", "Transparency", "Appearance", 0.9, Preferences.uiOpacityRange,
                    get: { Preferences.uiOpacity }, set: { theme.setOpacity(CGFloat($0)) }),
            .bool("prosper.uiFrost", "Frost", "Appearance", false, get: { Preferences.uiFrost }, set: { theme.setFrost($0) }),
        ] as [ControlSetting])
        // Completions
        r.append(contentsOf: [
            .bool("completionsEnabledByDefault", "Enable completions by default (off \u{21D2} per-app opt-in)", "Completions", true,
                  get: { Preferences.completionsEnabledByDefault }, set: { Preferences.completionsEnabledByDefault = $0 }),
            .bool("showAccessoryButton", "Show accessory button near the active text field", "Completions", true,
                  get: { Preferences.showAccessoryButton }, set: { Preferences.showAccessoryButton = $0 }),
            .bool("dismissOverlaysOnClick", "Hide ghost text and accessory button on mouse click", "Completions", true,
                  get: { Preferences.dismissOverlaysOnClick }, set: { Preferences.dismissOverlaysOnClick = $0 }),
            .choice("completionLength", "Length", "Completions", CompletionLength.medium,
                    get: { Preferences.completionLength }, set: { Preferences.completionLength = $0 }),
            .bool("midlineCompletionsEnabled", "Mid-line completions (suggest with text after the caret)", "Completions", true,
                  get: { Preferences.midlineCompletionsEnabled }, set: { Preferences.midlineCompletionsEnabled = $0 }),
            .bool("emojiSuggestionsEnabled", "Emoji suggestions (:name inline + in the command runner)", "Completions", true,
                  get: { Preferences.emojiSuggestionsEnabled }, set: { Preferences.emojiSuggestionsEnabled = $0 }),
            .bool("suppressOnTypo", "Don't complete when a typo is suspected", "Completions", false,
                  get: { Preferences.suppressOnTypo }, set: { Preferences.suppressOnTypo = $0 }),
            .bool("showSuggestedFixes", "Show suggested fixes (strike typo, propose correction)", "Completions", true,
                  get: { Preferences.showSuggestedFixes }, set: { Preferences.showSuggestedFixes = $0 }),
            .bool("trailingSpaceAfterWordAccept", "Add a space after accepting the last word (Tab)", "Completions", false,
                  get: { Preferences.trailingSpaceAfterWordAccept }, set: { Preferences.trailingSpaceAfterWordAccept = $0 }),
            .choice("emojiSkinTone", "Emoji skin tone", "Completions", EmojiSkinTone.none,
                    get: { Preferences.emojiSkinTone }, set: { Preferences.emojiSkinTone = $0 }),
            .choice("emojiGender", "Emoji gender", "Completions", EmojiGender.male,
                    get: { Preferences.emojiGender }, set: { Preferences.emojiGender = $0 }),
        ] as [ControlSetting])
        // Context
        r.append(contentsOf: [
            .bool("useScreenshotContext", "Use screenshots for context (multimodal)", "Context", true,
                  get: { Preferences.useScreenshotContext }, set: { Preferences.useScreenshotContext = $0 }),
            .bool("useOCRContext", "Read on-screen text for context (OCR)", "Context", true,
                  get: { Preferences.useOCRContext }, set: { Preferences.useOCRContext = $0 }),
            .bool("improveAppearanceFromScreenshot", "Use screenshots to improve suggestion appearance", "Context", true,
                  get: { Preferences.improveAppearanceFromScreenshot }, set: { Preferences.improveAppearanceFromScreenshot = $0 }),
        ] as [ControlSetting])
        // Personalization
        r.append(contentsOf: [
            .bool("collectTypingHistory", "Collect accepted completions for personalization", "Personalization", true,
                  get: { Preferences.collectTypingHistory }, set: { Preferences.collectTypingHistory = $0 }),
            .number("personalizeWordChoice", "Word-choice personalization", "Personalization", 0.5, 0...1,
                    get: { Preferences.personalizeWordChoice }, set: { Preferences.personalizeWordChoice = $0 }),
        ] as [ControlSetting])
        // Coding agent
        r.append(contentsOf: [
            .number("agentTemperature", "Temperature", "Model", 0.7, 0...2,
                    get: { Preferences.agentTemperature }, set: { Preferences.agentTemperature = $0 }),
            .number("agentTopP", "Top-p", "Model", 1.0, 0.1...1,
                    get: { Preferences.agentTopP }, set: { Preferences.agentTopP = $0 }),
            .bool("agentNetworkAccess", "Allow network access", "Permissions", false, get: { Preferences.agentNetworkAccess }, set: nil),
        ] as [ControlSetting])
        // Analytics, About
        r.append(contentsOf: [
            .bool("analyticsEnabled", "Share anonymous usage analytics", "Analytics", true, get: { Preferences.analyticsEnabled }, set: nil),
            .bool("automaticUpdateChecks", "Automatically check for updates", "About", true,
                  get: { Preferences.automaticUpdateChecks }, set: nil),
            .bool("allowBetaUpdates", "Receive beta (pre-release) updates", "About", false, get: { Preferences.allowBetaUpdates }, set: nil),
            .bool(TraceLog.key, "Verbose troubleshooting log", "About", false,
                  get: { Preferences.defaults.bool(forKey: TraceLog.key) }, set: nil),
        ] as [ControlSetting])
        // System Stats, Volume Mixer
        r.append(contentsOf: [
            .bool("systemStatsEnabled", "Show System Stats", "System Stats", false, get: { Preferences.systemStatsEnabled }, set: nil),
            .number("statsRefreshInterval", "Update interval", "System Stats", 5, 1...10,
                    get: { Preferences.statsRefreshInterval }, set: nil),
            .number("statsSensorsInterval", "Sensors interval", "System Stats", 10, 1...10,
                    get: { Preferences.statsSensorsInterval }, set: nil),
            .bool("mixerEnabled", "Enable volume mixer", "Volume Mixer", false, get: { Preferences.mixerEnabled }, set: nil),
            .bool("mixerIconEnabled", "Show Volume Mixer", "Volume Mixer", true, get: { Preferences.mixerIconEnabled }, set: nil),
            .bool(MixerDefaultsKey.hideInactiveApps, "Hide inactive apps", "Volume Mixer", true,
                  get: { Preferences.defaults.object(forKey: MixerDefaultsKey.hideInactiveApps) as? Bool ?? true },
                  set: { Preferences.defaults.set($0, forKey: MixerDefaultsKey.hideInactiveApps) }),
        ] as [ControlSetting])
        // Window snapping
        r.append(contentsOf: [
            .bool("dragSnapEnabled", "Enable drag-to-snap", "Windows", true, get: { Preferences.dragSnapEnabled }, set: nil),
            .choice("dragSnapModifier", "Snap modifier", "Windows", DragSnapModifier.none,
                    get: { Preferences.dragSnapModifier }, set: { Preferences.dragSnapModifier = $0 }),
            .number("dragSnapEdgeMargin", "Edge sensitivity", "Windows", 8, Preferences.dragSnapEdgeMarginRange,
                    get: { Double(Preferences.dragSnapEdgeMargin) }, set: { Preferences.dragSnapEdgeMargin = CGFloat($0) }),
            .number("dragSnapCornerSize", "Corner size", "Windows", 70, Preferences.dragSnapCornerSizeRange,
                    get: { Double(Preferences.dragSnapCornerSize) }, set: { Preferences.dragSnapCornerSize = CGFloat($0) }),
            .choice("snapMode", "Snap mode", "Windows", SnapMode.edges, get: { Preferences.snapMode }, set: { Preferences.snapMode = $0 }),
            .number("layoutGap", "Gap", "Windows", 8, Preferences.layoutGapRange,
                    get: { Double(Preferences.layoutGap) }, set: { Preferences.layoutGap = CGFloat($0) }),
        ] as [ControlSetting])
        return r
    }

    @MainActor static func setting(_ key: String) throws -> ControlSetting {
        guard let s = all().first(where: { $0.key == key }) else { throw ControlError("unknown setting '\(key)' (settings.schema lists them)") }
        return s
    }

    /// Validates every value first, then writes them all; the undo writes the old values back in reverse.
    @MainActor static func apply(_ values: [String: ControlJSON]) throws -> ControlChange {
        guard !values.isEmpty else { throw ControlError("values is empty") }
        var writes: [(ControlSetting, ControlJSON, ControlJSON)] = []
        for key in values.keys.sorted() {
            let s = try setting(key)
            guard s.set != nil else { throw ControlError("\(key) is changed in Settings only") }
            let v = try s.checked(values[key]!)
            writes.append((s, v, s.get()))
        }
        let done = writes // a let: the undo closure is Sendable and cannot capture a var
        for (s, new, _) in done { s.set?(new) }
        let summary: String = done.map { w -> String in "\(w.0.title) to \(describe(w.1))" }.joined(separator: ", ")
        let now: [String: ControlJSON] = Dictionary(uniqueKeysWithValues: done.map { w -> (String, ControlJSON) in (w.0.key, w.0.get()) })
        return ControlChange(summary: summary, result: .object(now)) {
            for (s, _, old) in done.reversed() { s.set?(old) }
        }
    }

    private static func describe(_ v: ControlJSON) -> String {
        switch v {
        case .bool(let b): b ? "on" : "off"
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): s
        default: v.typeName
        }
    }
}

extension ControlRegistry {
    /// #1810: settings.schema, settings.get, settings.set. The supervisor adds `ControlRegistry.registerSettings(&r)`
    /// to `standard()` on landing.
    static func registerSettings(_ r: inout ControlRegistry) {
        r.register(ControlCommand(name: "settings.schema",
                                  summary: "Every user-facing setting: key, title, section, type, allowed values or range, current value, default, writable.",
                                  args: [:], mutates: false) { _, _ in
            .object(["settings": .array(ControlSettings.all().map { s -> ControlJSON in s.row })])
        })
        r.register(ControlCommand(name: "settings.get", summary: "One setting's current value.",
                                  args: ["key": ControlArg(type: "string", required: true, summary: "a key from settings.schema")],
                                  mutates: false) { _, args in
            guard case .string(let key)? = args["key"] else { throw ControlError("missing argument 'key' for settings.get") }
            let value = try ControlSettings.setting(key).get()
            return .object(["key": .string(key), "value": value])
        })
        r.register(.change(name: "settings.set",
                           summary: "Change one or more settings: {\"values\": {\"<key>\": <value>, ...}}. All are checked before any is written; Undo restores them.",
                           args: ["values": ControlArg(type: "object", required: true, summary: "key to new value, keys from settings.schema")]) { _, args in
            guard case .object(let values)? = args["values"] else { throw ControlError("missing argument 'values' for settings.set") }
            return try ControlSettings.apply(values)
        })
    }
}
