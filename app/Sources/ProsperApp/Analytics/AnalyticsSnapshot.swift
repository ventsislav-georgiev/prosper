import Foundation

/// Builds the flat property dictionary sent to Aptabase once a day. Aptabase props
/// accept only String and Number values, so every boolean is emitted as Int 0/1.
///
/// PII SAFETY — this is an explicit ALLOWLIST. Every value is referenced by name
/// below; we never iterate `UserDefaults`. Free-text / identifying prefs (userName,
/// customInstructions, perAppCustomInstructions, agentPersona, agentWorkingDirectory,
/// the bundle-id / domain sets, MCP & hook contents) are NEVER included — only their
/// COUNTS. Adding a new pref does nothing here until it is consciously added.
@MainActor
enum AnalyticsSnapshot {

    /// The single `daily_snapshot` event payload. Every key is prefixed with the
    /// module / feature it comes from (`meta_`, `general_`, `clipboard_`,
    /// `completions_`, `emoji_`, `context_`, `personalization_`, `updates_`,
    /// `onboarding_`, `agent_`, `apps_`, `quicklinks_`, `quickdirs_`, `shortcuts_`,
    /// `extensions_`). Bools are emitted as Int 0/1.
    static func build(registry: ExtensionRegistry? = SettingsHooks.shared.extensionRegistry) -> [String: Any] {
        var p: [String: Any] = [:]
        func b(_ v: Bool) -> Int { v ? 1 : 0 }

        // meta — identity & build
        p["meta_anon_id"] = AnalyticsStore.anonID()
        p["meta_app_version"] = AppInfo.shortVersion

        // general — startup, menu bar, dock
        p["general_launch_at_login"] = b(Preferences.launchAtLogin)
        p["general_show_menu_bar_icon"] = b(Preferences.showMenuBarIcon)
        p["general_show_dock_icon"] = b(Preferences.showDockIcon)

        // clipboard
        p["clipboard_history_enabled"] = b(Preferences.clipboardHistoryEnabled)
        p["clipboard_history_max_items"] = Preferences.clipboardHistoryMaxItems
        p["clipboard_use_context"] = b(Preferences.useClipboardContext)

        // completions — inline autocomplete + the core/draft models it runs
        p["completions_autocomplete_enabled"] = b(Preferences.autocompleteEnabled)
        p["completions_enabled_by_default"] = b(Preferences.completionsEnabledByDefault)
        p["completions_length"] = Preferences.completionLength.rawValue
        p["completions_midline_enabled"] = b(Preferences.midlineCompletionsEnabled)
        p["completions_suppress_on_typo"] = b(Preferences.suppressOnTypo)
        p["completions_trailing_space_after_accept"] = b(Preferences.trailingSpaceAfterWordAccept)
        p["completions_show_accessory_button"] = b(Preferences.showAccessoryButton)
        p["completions_dismiss_overlays_on_click"] = b(Preferences.dismissOverlaysOnClick)
        p["completions_show_suggested_fixes"] = b(Preferences.showSuggestedFixes)
        p["completions_speculative_decoding"] = b(Preferences.speculativeDecodingEnabled)
        p["completions_num_draft_tokens"] = Preferences.numDraftTokens
        p["completions_kv_bits"] = Preferences.inlineKVBits
        p["completions_model"] = Preferences.coreModel
        p["completions_draft_model"] = Preferences.draftModelId

        // emoji
        p["emoji_suggestions_enabled"] = b(Preferences.emojiSuggestionsEnabled)
        p["emoji_skin_tone"] = Preferences.emojiSkinTone.rawValue
        p["emoji_gender"] = Preferences.emojiGender.rawValue

        // context — vision/OCR completion context
        p["context_use_screenshot"] = b(Preferences.useScreenshotContext)
        p["context_use_ocr"] = b(Preferences.useOCRContext)
        p["context_improve_appearance"] = b(Preferences.improveAppearanceFromScreenshot)

        // personalization — typing history + LoRA
        p["personalization_collect_typing_history"] = b(Preferences.collectTypingHistory)
        p["personalization_lora_enabled"] = b(Preferences.loraEnabled)
        p["personalization_lora_serving_active"] = b(Preferences.loraServingActive)

        // updates
        p["updates_automatic_checks"] = b(Preferences.automaticUpdateChecks)
        p["updates_allow_beta"] = b(Preferences.allowBetaUpdates)

        // onboarding
        p["onboarding_completed"] = b(Preferences.onboardingCompleted)

        // agent — coding agent + its model and customizable items (counts only)
        p["agent_model"] = Preferences.agentModel
        p["agent_approval_policy"] = Preferences.agentApprovalPolicy
        p["agent_bypass_all"] = b(Preferences.agentBypassAll)
        p["agent_network_access"] = b(Preferences.agentNetworkAccess)
        p["agent_count_mcp_servers"] = Preferences.mcpServers.count
        p["agent_count_hooks"] = Preferences.hooks.count
        p["agent_count_commands"] = CommandStore.all().count
        // Personas mix shipped built-ins (Build/Plan) with user markdown files —
        // keep the two apart (a user override of a built-in id counts as user).
        let personas = AgentPersonaStore.all()
        p["agent_count_personas_system"] = personas.filter(\.isBuiltIn).count
        p["agent_count_personas_user"] = personas.filter { !$0.isBuiltIn }.count
        p["agent_count_plugins"] = pluginCount()

        // apps — per-app/domain overrides (counts only — never the bundle ids).
        // The disabled set seeds from `defaultDisabledBundleIds` (password managers,
        // editors, launchers); split the shipped defaults still active from anything
        // the user added on top, so adoption isn't drowned by the ~19 seeded ids.
        let disabled = Preferences.disabledBundleIds
        let disabledSystem = disabled.intersection(Preferences.defaultDisabledBundleIds)
        p["apps_count_disabled_system"] = disabledSystem.count
        p["apps_count_disabled_user"] = disabled.count - disabledSystem.count
        p["apps_count_enabled"] = Preferences.enabledBundleIds.count
        p["apps_count_disable_tab"] = Preferences.disableTabBundleIds.count
        p["apps_count_compat"] = Preferences.improveCompatBundleIds.count
        p["apps_count_disabled_domains"] = Preferences.disabledDomains.count
        p["apps_count_per_app_instructions"] = Preferences.perAppCustomInstructions.count

        // quicklinks / quickdirs / shortcuts (counts only)
        p["quicklinks_count"] = QuicklinkStore.all().count
        p["quickdirs_count"] = QuickdirStore.all().count
        p["shortcuts_count_custom"] = ShortcutStore.customShortcuts().count

        // extensions — user-extension count (no per-id detail) + total commands.
        if let registry {
            let userExts = registry.records.filter { !$0.isSystem }
            p["extensions_count_user"] = userExts.count
            p["extensions_count_user_commands"] = userExts
                .flatMap { $0.manifest.contributes?.allCommands ?? [] }.count
            p["extensions_count_system"] = registry.records.filter { $0.isSystem }.count
        }
        // Per-SYSTEM-extension usage counters (calc, units, translate, …). Only
        // system ids are ever bumped, so the whole dict is safe to send.
        for (id, n) in AnalyticsStore.usageCounts() {
            p["extensions_use_\(sanitize(id))"] = n
        }

        return p
    }

    /// Number of installed Bun (opencode JS/TS) plugins.
    private static func pluginCount() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: BunHarness.pluginsDir.path) else { return 0 }
        return names.filter {
            !$0.hasPrefix(".") && $0.range(of: #"\.(m?[jt]s)$"#, options: .regularExpression) != nil
        }.count
    }

    /// Non-alphanumerics → '_' so an extension id is a safe property key
    /// ("com.prosper.calc" → "com_prosper_calc").
    static func sanitize(_ s: String) -> String {
        String(s.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// Pretty-printed JSON of the payload, for the Settings transparency view.
    static func prettyJSON(registry: ExtensionRegistry? = SettingsHooks.shared.extensionRegistry) -> String {
        let payload = build(registry: registry)
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
