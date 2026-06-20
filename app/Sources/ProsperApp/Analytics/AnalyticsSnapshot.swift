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
    /// `agent_`, `apps_`, `quicklinks_`, `quickdirs_`, `shortcuts_`,
    /// `extensions_`). Bools are emitted as Int 0/1.
    static func build(registry: ExtensionRegistry? = SettingsHooks.shared.extensionRegistry) -> [String: Any] {
        var p: [String: Any] = [:]
        func b(_ v: Bool) -> Int { v ? 1 : 0 }

        // A disabled feature's sub-settings carry no signal (they're inert), so we
        // gate them: the master toggle is always sent, the detail props only when
        // the feature is on. Same idea as Sync skipping inactive entries.
        let autocomplete = Preferences.autocompleteEnabled
        // The inline model is shared with Translate, so it's still meaningful when
        // autocomplete is off but Translate is live.
        let translateLive = registry?.record(id: "com.prosper.translate")?.isLive ?? false

        // meta — identity & build
        p["meta_anon_id"] = AnalyticsStore.anonID()
        p["meta_app_version"] = AppInfo.shortVersion

        // general — startup, menu bar, dock
        p["general_launch_at_login"] = b(Preferences.launchAtLogin)
        p["general_show_menu_bar_icon"] = b(Preferences.showMenuBarIcon)
        p["general_show_dock_icon"] = b(Preferences.showDockIcon)

        // clipboard
        let clipboardOn = Preferences.clipboardHistoryEnabled
        p["clipboard_history_enabled"] = b(clipboardOn)
        if clipboardOn {
            p["clipboard_history_max_items"] = Preferences.clipboardHistoryMaxItems
            p["clipboard_use_context"] = b(Preferences.useClipboardContext)
        }

        // completions — inline autocomplete + the core/draft models it runs
        p["completions_autocomplete_enabled"] = b(autocomplete)
        if autocomplete {
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
            p["completions_draft_model"] = Preferences.draftModelId
            // context (vision/OCR) only feeds inline completions.
            p["context_use_screenshot"] = b(Preferences.useScreenshotContext)
            p["context_use_ocr"] = b(Preferences.useOCRContext)
            p["context_improve_appearance"] = b(Preferences.improveAppearanceFromScreenshot)
        }
        // The core model is used by both autocomplete and Translate.
        if autocomplete || translateLive {
            p["completions_model"] = Preferences.coreModel
        }

        // emoji
        let emojiOn = Preferences.emojiSuggestionsEnabled
        p["emoji_suggestions_enabled"] = b(emojiOn)
        if emojiOn {
            p["emoji_skin_tone"] = Preferences.emojiSkinTone.rawValue
            p["emoji_gender"] = Preferences.emojiGender.rawValue
        }

        // personalization — typing history + LoRA
        let loraOn = Preferences.loraEnabled
        p["personalization_collect_typing_history"] = b(Preferences.collectTypingHistory)
        p["personalization_lora_enabled"] = b(loraOn)
        if loraOn {
            p["personalization_lora_serving_active"] = b(Preferences.loraServingActive)
            p["personalization_lora_rank"] = Preferences.loraRank
            p["personalization_lora_num_layers"] = Preferences.loraNumLayers
            p["personalization_lora_iterations"] = Preferences.loraIterations
            p["personalization_lora_min_samples"] = Preferences.loraMinSamples
            p["personalization_lora_ab_min_samples"] = Preferences.loraABMinSamples
        }

        // snippets — text expansion
        let snippetsOn = Preferences.snippetsEnabled
        p["snippets_enabled"] = b(snippetsOn)
        if snippetsOn {
            p["snippets_auto_expand"] = b(Preferences.snippetsAutoExpand)
            p["snippets_expand_on_word_boundary"] = b(Preferences.snippetsExpandOnWordBoundary)
            p["snippets_restore_clipboard"] = b(Preferences.snippetsRestoreClipboard)
        }

        // updates
        p["updates_automatic_checks"] = b(Preferences.automaticUpdateChecks)
        p["updates_allow_beta"] = b(Preferences.allowBetaUpdates)

        // sync + theme — feature adoption / customization
        p["sync_enabled"] = b(SyncCoordinator.shared.enabled)
        p["theme_active_id"] = ThemeStore.shared.activeID

        // agent — coding agent + its model and customizable items (counts only)
        let agentOn = Preferences.agentEnabled
        p["agent_enabled"] = b(agentOn)
        if agentOn {
            p["agent_model"] = Preferences.agentModel
            p["agent_approval_policy"] = Preferences.agentApprovalPolicy
            p["agent_bypass_all"] = b(Preferences.agentBypassAll)
            p["agent_network_access"] = b(Preferences.agentNetworkAccess)
            // Doubles are the only non-integer numerics in the payload. A NaN/Inf would
            // make JSONSerialization throw and silently block EVERY future send, so emit
            // them only when finite (a corrupt pref just drops that one prop).
            if Preferences.agentTemperature.isFinite { p["agent_temperature"] = Preferences.agentTemperature }
            if Preferences.agentTopP.isFinite { p["agent_top_p"] = Preferences.agentTopP }
            p["agent_count_mcp_servers"] = Preferences.mcpServers.count
            p["agent_count_hooks"] = Preferences.hooks.count
            p["agent_count_commands"] = CommandStore.all().count
            // Personas mix shipped built-ins (Build/Plan) with user markdown files —
            // keep the two apart (a user override of a built-in id counts as user).
            let personas = AgentPersonaStore.all()
            p["agent_count_personas_system"] = personas.filter(\.isBuiltIn).count
            p["agent_count_personas_user"] = personas.filter { !$0.isBuiltIn }.count
            p["agent_count_plugins"] = pluginCount()
        }

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

        // extensions — counts (no per-id detail), computed in ONE pass over records
        // (avoids re-filtering the array four times). `liveIDs` lets the usage-counter
        // loop below do O(1) membership instead of a linear `record(id:)` per entry.
        let usage = AnalyticsStore.usageCounts()
        if let registry {
            var userCount = 0, userCommands = 0, systemCount = 0, disabledCount = 0
            var liveIDs = Set<String>()
            for r in registry.records {
                if r.isSystem {
                    systemCount += 1
                } else {
                    userCount += 1
                    userCommands += r.manifest.contributes?.allCommands.count ?? 0
                }
                if !r.enabled { disabledCount += 1 }
                if r.isLive { liveIDs.insert(r.id) }
            }
            p["extensions_count_user"] = userCount
            p["extensions_count_user_commands"] = userCommands
            p["extensions_count_system"] = systemCount
            p["extensions_count_disabled"] = disabledCount
            // Per-SYSTEM-extension usage counters (calc, units, translate, …). Only
            // system ids are ever bumped, so the dict is safe to send. Skip ids that
            // aren't currently live — a disabled extension's usage carries no signal.
            for (id, n) in usage where liveIDs.contains(id) {
                p["extensions_use_\(sanitize(id))"] = n
            }
        } else {
            // No registry (prettyJSON / tests). The service delays *real* sends until
            // the registry is present, so completeness isn't a concern here; emit the
            // raw usage counters unfiltered for the transparency view.
            for (id, n) in usage {
                p["extensions_use_\(sanitize(id))"] = n
            }
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
