import Foundation
import AppKit

/// Max length band for inline completions, mapped to a token budget.
enum CompletionLength: String, CaseIterable {
    case short
    case medium
    case long

    /// Target number of words to generate. The inline suggestion is accepted
    /// word-by-word (Tab), so a shorter target shows up faster and the user walks
    /// through it; this is the primary latency lever (decode cost is ~linear in
    /// tokens). The word cap is enforced during streaming in `MLXEngine`.
    var maxWords: Int {
        switch self {
        case .short: return 3   // next 1-3 words
        case .medium: return 5  // next 3-5 words
        case .long: return 7    // next 5-7 words
        }
    }

    /// Hard ceiling on generated tokens — a safety bound above the expected word
    /// count (tokens != words). The word cap is the real limiter; this just caps
    /// the worst case if a "word" runs long or no boundary is hit.
    var maxTokens: Int {
        switch self {
        case .short: return 24
        case .medium: return 48
        case .long: return 72
        }
    }

    var title: String {
        switch self {
        case .short: return "Short (1-3 words)"
        case .medium: return "Medium (3-5 words)"
        case .long: return "Long (5-7 words)"
        }
    }
}

/// Modifier key for the numbered quick-select shortcuts — clipboard history
/// rows (⌘1…⌘0) and the top runner results (⌘1…⌘5). User-configurable.
enum QuickSelectModifier: String, CaseIterable {
    case command
    case control

    var glyph: String { self == .command ? "\u{2318}" : "\u{2303}" }   // ⌘ / ⌃
    var title: String { self == .command ? "Command (⌘)" : "Control (⌃)" }
}

/// Pure, keyboard-layout-coupled mapping for the numbered quick-select shortcuts.
/// Lives here (not in the AppKit panels) so it is unit-testable without an event
/// loop, and so the clipboard panel (⌘1…⌘0) and the runner (⌘1…⌘5) share ONE
/// keycode table instead of duplicating it. Hot path: called once per keyDown
/// while a panel is open — keep it a branch-only switch (no allocation, no I/O).
enum QuickSelect {
    /// How many of the top runner results get a numbered shortcut + badge. The
    /// handler guard and both badge views read this so they can't drift apart.
    /// (The clipboard panel exposes all ten visible slots and caps in `visibleSlots`.)
    static let runnerTopCount = 5

    /// ANSI US top-row digit key codes → 0-based slot: 1→0 … 9→8, 0→9.
    /// Returns nil for non-digit keys. Callers cap the range (clipboard keeps all
    /// ten; the runner ignores slots ≥ 5).
    static func slot(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 0  // 1
        case 19: return 1  // 2
        case 20: return 2  // 3
        case 21: return 3  // 4
        case 23: return 4  // 5
        case 22: return 5  // 6
        case 26: return 6  // 7
        case 28: return 7  // 8
        case 25: return 8  // 9
        case 29: return 9  // 0
        default: return nil
        }
    }

    /// True when `flags` carry exactly `expected` among the real modifiers
    /// (command/control/option/shift) — so ⌘1 matches but ⌘⌥1 does not — while
    /// ignoring Caps Lock / fn / numeric-pad bits (those must not block the
    /// shortcut). Used by both panels' keyDown paths.
    static func modifierMatches(_ flags: NSEvent.ModifierFlags,
                                expected: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option, .shift]) == expected
    }
}

/// Preferred emoji skin tone (Fitzpatrick modifier U+1F3FB…U+1F3FF), or none.
enum EmojiSkinTone: String, CaseIterable {
    case none, light, mediumLight, medium, mediumDark, dark

    /// The Unicode skin-tone modifier scalar, or nil for `.none`.
    var modifier: String? {
        switch self {
        case .none: return nil
        case .light: return "\u{1F3FB}"
        case .mediumLight: return "\u{1F3FC}"
        case .medium: return "\u{1F3FD}"
        case .mediumDark: return "\u{1F3FE}"
        case .dark: return "\u{1F3FF}"
        }
    }

    var title: String {
        switch self {
        case .none: return "Default"
        case .light: return "Light"
        case .mediumLight: return "Medium-Light"
        case .medium: return "Medium"
        case .mediumDark: return "Medium-Dark"
        case .dark: return "Dark"
        }
    }
}

/// Preferred gender presentation for gendered emoji (person/professional roles).
enum EmojiGender: String, CaseIterable {
    case neutral, female, male

    var title: String {
        switch self {
        case .neutral: return "Neutral"
        case .female: return "Female"
        case .male: return "Male"
        }
    }
}

/// Centralized UserDefaults-backed preferences.
enum Preferences {
    private static var defaults: UserDefaults { UserDefaults.standard }

    private enum Keys {
        static let autocompleteEnabled = "autocompleteEnabled"
        static let agentEnabled = "agentEnabled"
        static let systemStatsEnabled = "systemStatsEnabled"
        static let fanManualEnabled = "fanManualEnabled"
        static let fanManualConsent = "fanManualConsent"
        static let fanTargets = "fanTargets"
        static let statsRefreshInterval = "statsRefreshInterval"
        static let sensorsHeadlineSensor = "sensorsHeadlineSensor"
        static let dragSnapEnabled = "dragSnapEnabled"
        static let dragSnapStyle = "dragSnapStyle"
        static let dragSnapModifier = "dragSnapModifier"
        static let dragSnapEdgeMargin = "dragSnapEdgeMargin"
        static let dragSnapCornerSize = "dragSnapCornerSize"
        static let dragSnapIgnoredBundleIds = "dragSnapIgnoredBundleIds"
        static let runnerPlacement = "runnerPlacement"
        static let snapMode = "snapMode"
        static let layoutGap = "layoutGap"
        static let layoutStoreJSON = "layoutStoreJSON"
        static let layoutStoreBackupJSON = "layoutStoreBackupJSON"   // newer-schema blob preserved on downgrade
        static let menuBarStoreJSON = "menuBarStoreJSON"
        static let menuBarStoreBackupJSON = "menuBarStoreBackupJSON"
        static let menuBarOrderStoreJSON = "menuBarOrderStoreJSON"
        static let menuBarOrderStoreBackupJSON = "menuBarOrderStoreBackupJSON"
        static let uiScale = "prosper.uiScale"
        static let uiOpacity = "prosper.uiOpacity"
        static let uiFrost = "prosper.uiFrost"
        static let coreModel = "coreModel"
        static let launchAtLogin = "launchAtLogin"
        static let completionLength = "completionLength"
        static let customInstructions = "customInstructions"
        static let userName = "userName"
        static let userLanguages = "userLanguages"
        static let voiceStyle = "voiceStyle"
        static let disabledBundleIds = "disabledBundleIds"
        static let disableTabBundleIds = "disableTabBundleIds"
        static let quickSelectModifier = "quickSelectModifier"
        static let clipboardHistoryEnabled = "clipboardHistoryEnabled"
        static let clipboardHistoryMaxItems = "clipboardHistoryMaxItems"
        static let completionsEnabledByDefault = "completionsEnabledByDefault"
        static let enabledBundleIds = "enabledBundleIds"
        static let useClipboardContext = "useClipboardContext"
        static let midlineCompletionsEnabled = "midlineCompletionsEnabled"
        static let emojiSuggestionsEnabled = "emojiSuggestionsEnabled"
        static let suppressOnTypo = "suppressOnTypo"
        static let collectTypingHistory = "collectTypingHistory"
        static let personalizeWordChoice = "personalizeWordChoice"
        static let disabledDomains = "disabledDomains"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let allowBetaUpdates = "allowBetaUpdates"
        static let useScreenshotContext = "useScreenshotContext"
        static let improveAppearanceFromScreenshot = "improveAppearanceFromScreenshot"
        static let useOCRContext = "useOCRContext"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockIcon = "showDockIcon"
        static let showAccessoryButton = "showAccessoryButton"
        static let dismissOverlaysOnClick = "dismissOverlaysOnClick"
        static let trailingSpaceAfterWordAccept = "trailingSpaceAfterWordAccept"
        static let showSuggestedFixes = "showSuggestedFixes"
        static let emojiSkinTone = "emojiSkinTone"
        static let emojiGender = "emojiGender"
        static let improveCompatBundleIds = "improveCompatBundleIds"
        static let perAppCustomInstructions = "perAppCustomInstructions"
        static let modelDirMigrated = "modelDirMigrated"
        static let inlineKVBits = "inlineKVBits"
        static let speculativeDecodingEnabled = "speculativeDecodingEnabled"
        static let draftModelId = "draftModelId"
        static let numDraftTokens = "numDraftTokens"
        static let appOverridesMigrated = "appOverridesMigrated"
        static let enhancedUIHelped = "enhancedUIHelped"
        // Coding-agent model (separate ladder from the inline `coreModel`). See
        // AgentModelRegistry.swift.
        static let agentModel = "agentModel"
        static let agentWorkingDirectory = "agentWorkingDirectory"
        // Remote Terminal (DchTerm): serve dch sessions over Tailscale.
        static let remoteTerminalEnabled = "remoteTerminalEnabled"
        static let isolateRemoteSessions = "isolateRemoteSessions"
        // MCP servers for the coding agent (JSON-encoded [MCPServer]). Rendered into
        // codex config.toml at harness spawn. See MCPServer.swift.
        static let agentMCPServers = "agentMCPServers"
        // Lifecycle hooks for the coding agent (JSON-encoded [HookRule]). Rendered into
        // codex config.toml at harness spawn. See HookRule.swift.
        static let agentHooks = "agentHooks"
        // Selected persona id (system-prompt preset). See AgentPersonaStore.swift.
        static let agentPersona = "agentPersona"
        // Permissions (F4). Bypass = codex never-approve + danger-full-access ("YOLO").
        static let agentBypassAll = "agentBypassAll"
        static let agentApprovalPolicy = "agentApprovalPolicy"   // ApprovalPolicy raw
        static let agentNetworkAccess = "agentNetworkAccess"
        static let agentWritableRoots = "agentWritableRoots"     // extra sandbox roots
        // Sampling for the coding agent. Read per-request by the LLM server (no
        // harness respawn needed), overriding whatever codex sends.
        static let agentTemperature = "agentTemperature"
        static let agentTopP = "agentTopP"
        // WS6 — On-device LoRA personalization (all OFF / inert by default).
        static let loraEnabled = "loraEnabled"
        static let loraServingActive = "loraServingActive"
        static let loraRank = "loraRank"
        static let loraNumLayers = "loraNumLayers"
        static let loraIterations = "loraIterations"
        static let loraMinSamples = "loraMinSamples"
        static let loraABMinSamples = "loraABMinSamples"
        static let loraLastTrained = "loraLastTrained"
        static let loraAdapterShown = "loraAdapterShown"
        static let loraAdapterAccepted = "loraAdapterAccepted"
        static let loraBaselineShown = "loraBaselineShown"
        static let loraBaselineAccepted = "loraBaselineAccepted"
        // Opt-out usage analytics (Aptabase). On by default; see Analytics/.
        static let analyticsEnabled = "analyticsEnabled"
        // Snippets (text-expansion library + inline auto-expansion). See Snippets/.
        static let snippetsEnabled = "snippetsEnabled"
        static let snippetsAutoExpand = "snippetsAutoExpand"
        static let snippetsExpandOnWordBoundary = "snippetsExpandOnWordBoundary"
        static let snippetsRestoreClipboard = "snippetsRestoreClipboard"
        static let snippetsIgnoredBundleIds = "snippetsIgnoredBundleIds"
    }

    /// Bundle ids where inline snippet auto-expansion is suppressed by default.
    /// Prosper's own surfaces + password managers + launchers, mirroring the
    /// autocomplete denylist intent (text expansion in a password field or a
    /// command palette is unwanted / unsafe).
    static let defaultSnippetsIgnoredBundleIds: Set<String> = [
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "com.raycast.macos",
        "com.runningwithcrows.alfred",
        "com.apple.Spotlight",
    ]

    /// Gemma 4 E2B instruct, uniform 6-bit (~4.7 GB). NOT in the picker (QAT-only
    /// menu); retained as a revert fallback for installs that already downloaded it.
    static let defaultModelId = "mlx-community/gemma-4-e2b-it-6bit"

    /// QAT model ladder (the ONLY checkpoints offered in the picker). All are
    /// quantization-aware-trained Gemma 4 (E2B = effective ~2B, E4B = effective ~4B)
    /// and load via the mlx-swift-lm QAT patch (heterogeneous quant + KV-sharing):
    /// the checkpoints are heterogeneous (per-layer) quant AND omit K/V proj+norm on
    /// KV-shared layers; the patch (`app/patches/mlx-swift-lm-qat.patch`, re-applied
    /// by `scripts/apply-patches.sh`) makes the per-layer projection quantizable and
    /// gates K/V proj+norm to non-shared layers.
    /// Within a base, more bits = sharper output + larger download/RAM; bigger base
    /// = smarter at every bit width. Sizes are total safetensors on disk. The 12B
    /// (dense) and 26B-A4B (MoE) bases are offered too for high-RAM Macs. The dense
    /// **31B**, the `-assistant-*` finetune, and experimental dtypes
    /// (mxfp4/nvfp4/bf16) remain excluded as unfit for the on-device inline hot path.
    static let qatE2B4Id = "mlx-community/gemma-4-E2B-it-qat-4bit"  // ~4.3 GB
    static let qatE2B6Id = "mlx-community/gemma-4-E2B-it-qat-6bit"  // ~5.1 GB
    static let qatE2B8Id = "mlx-community/gemma-4-E2B-it-qat-8bit"  // ~5.9 GB
    static let qatE4B4Id = "mlx-community/gemma-4-E4B-it-qat-4bit"  // ~6.8 GB
    static let qatE4B6Id = "mlx-community/gemma-4-E4B-it-qat-6bit"  // ~7.8 GB
    static let qatE4B8Id = "mlx-community/gemma-4-E4B-it-qat-8bit"  // ~8.9 GB
    // Heavier full-size Gemma 4 QAT (dense 12B and the 26B-A4B MoE — 26B total,
    // only ~4B active per token, so it runs closer to E4B speed than its size
    // implies). Same QAT load path (heterogeneous quant + KV-sharing patch) as the
    // E-series. Offered for high-RAM Macs that want sharper completions; the inline
    // hot-path tradeoff is download/RAM and (for the dense 12B) latency.
    static let qat12B4Id = "mlx-community/gemma-4-12B-it-qat-4bit"        // ~6.7 GB
    static let qat12B6Id = "mlx-community/gemma-4-12B-it-qat-6bit"        // ~9.6 GB
    static let qat12B8Id = "mlx-community/gemma-4-12B-it-qat-8bit"        // ~12.6 GB
    static let qat26B4Id = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"    // ~14 GB · MoE 4B active
    static let qat26B6Id = "mlx-community/gemma-4-26B-A4B-it-qat-6bit"    // ~20 GB · MoE 4B active
    static let qat26B8Id = "mlx-community/gemma-4-26B-A4B-it-qat-8bit"    // ~27 GB · MoE 4B active

    /// Recommended default: Gemma 4 E4B, **QAT 8-bit** (~8.9 GB) — the largest,
    /// smartest, highest-RAM option in the ladder (biggest base × most bits =
    /// sharpest completions). This is the `coreModel` fallback so a fresh install
    /// runs it; users can step down the ladder from the AI Model picker to trade
    /// quality for RAM/speed.
    static let recommendedModelId = qatE4B8Id

    /// Every picker-offered model, smallest→largest. Drives the AI Model picker and
    /// the revert-target search.
    ///
    /// The full-size 12B/26B QAT checkpoints are deliberately EXCLUDED: the vendored
    /// mlx-swift-lm fork has no loader for them. The 12B dense ships `model_type:
    /// gemma4_unified` (Gemma4UnifiedForConditionalGeneration) which is not registered
    /// in LLMModelFactory, and the 26B-A4B is a 128-expert MoE whose weights don't map
    /// onto the dense `Gemma4Model`. Both fail at load. Re-add them here (and to the
    /// picker `models` array) only once those architectures are ported AND verified to
    /// load — see `unsupportedModelIds`.
    static let selectableModelIds: [String] = [
        qatE2B4Id, qatE2B6Id, qatE2B8Id, qatE4B4Id, qatE4B6Id, qatE4B8Id,
    ]

    /// Checkpoints that exist on Hugging Face and have id constants above, but cannot
    /// be loaded by the current fork (see `selectableModelIds`). `coreModel` rewrites a
    /// stored value from this set back to `recommendedModelId` so a user who selected
    /// one before it was pulled from the picker isn't stuck on a model that never loads.
    static let unsupportedModelIds: Set<String> = [
        qat12B4Id, qat12B6Id, qat12B8Id, qat26B4Id, qat26B6Id, qat26B8Id,
    ]

    /// Lightest uniform option, NOT in the picker (QAT-only menu). Gemma 4 E2B,
    /// uniform **4-bit** (~3.6 GB). Still used as the speculative-decoding draft
    /// (`defaultDraftModelId`) and as a revert fallback for legacy installs.
    static let liteModelId = "mlx-community/gemma-4-e2b-it-4bit"

    /// Uniform E4B 6-bit, NOT in the picker (QAT-only menu). Retained as a revert
    /// fallback for installs that already downloaded it.
    static let alternateModelId = "mlx-community/gemma-4-e4b-it-6bit"

    // MARK: - Speculative decoding (WS2)

    /// Default draft model for speculative decoding (WS2). The draft proposes
    /// `numDraftTokens` cheap tokens per round; the main (verifier) model accepts or
    /// rejects them in a single forward pass. The library's `SpeculativeTokenIterator`
    /// owns the accept/verify loop — we only supply both models.
    ///
    /// TOKENIZER-MATCH REQUIREMENT (critical): the draft and main models MUST share
    /// the **exact same tokenizer**, or `SpeculativeTokenIterator` decode throws /
    /// produces garbage — the verifier maps the draft's token ids onto its own logits,
    /// so the id↔piece mapping must be identical. We default the draft to the uniform
    /// **4-bit** sibling of the default 6-bit main model (`gemma-4-e2b-it-4bit` vs
    /// `gemma-4-e2b-it-6bit`): same Gemma 4 E2B checkpoint, same `tokenizer.model`,
    /// just a lighter/faster quant — so it is guaranteed tokenizer-compatible and is
    /// the smallest published Gemma-4-family MLX checkpoint (cross-family choices like
    /// Gemma 3 do NOT share Gemma 4's tokenizer and would break). If the user changes
    /// `coreModel`, they must pick a draft from the **same model family/tokenizer**.
    static let defaultDraftModelId = "mlx-community/gemma-4-e2b-it-4bit"

    /// Whether speculative decoding is used for inline completions (WS2). **Off by
    /// default** so the shipped behavior is unchanged. When on AND the draft model is
    /// loaded, the inline path runs the speculative iterator; otherwise it transparently
    /// falls back to the single-model `generateInline`.
    ///
    /// MEMORY COST: enabling this loads a SECOND model resident alongside the main
    /// model, materially raising RSS (a 4-bit E2B draft is hundreds of MB on top of the
    /// 6-bit main weights). The 384 MB GPU buffer-cache cap (`configureMemoryLimits`)
    /// is unchanged, but the draft's weights live in *active* memory, not the cache.
    static var speculativeDecodingEnabled: Bool {
        get { defaults.bool(forKey: Keys.speculativeDecodingEnabled) } // absent → false
        set { defaults.set(newValue, forKey: Keys.speculativeDecodingEnabled) }
    }

    /// Hugging Face MLX model id of the draft model. Defaults to `defaultDraftModelId`.
    /// MUST share the main model's tokenizer (see `defaultDraftModelId`).
    static var draftModelId: String {
        get { defaults.string(forKey: Keys.draftModelId) ?? defaultDraftModelId }
        set { defaults.set(newValue, forKey: Keys.draftModelId) }
    }

    // MARK: - Drag-to-snap window management

    /// Master switch for Rectangle-style drag-to-edge window snapping. Defaults ON —
    /// it's a headline feature and still gated by Accessibility trust before any
    /// monitor starts. Absent key → treated as on.
    static var dragSnapEnabled: Bool {
        get { defaults.object(forKey: Keys.dragSnapEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.dragSnapEnabled) }
    }

    /// Footprint preview look: flat (default, Rectangle-parity translucent fill —
    /// lighter to draw) or vibrancy (blur + theme accent, the richer default).
    /// Stored as a raw string; absence ⇒ vibrancy.
    static var dragSnapStyle: FootprintWindow.Style {
        get { defaults.string(forKey: Keys.dragSnapStyle) == "flat" ? .flat : .vibrancy }
        set { defaults.set(newValue == .vibrancy ? "vibrancy" : "flat", forKey: Keys.dragSnapStyle) }
    }

    /// Global UI size multiplier (Appearance → UI Size). Default 1.0 = unchanged.
    /// Clamped so a stale/garbage default can never blow the layout up or collapse it.
    static let uiScaleRange: ClosedRange<Double> = 0.7...1.45
    static var uiScale: Double {
        get {
            // `object(forKey:)` so an unset default reads as 1.0, not 0.0.
            guard defaults.object(forKey: Keys.uiScale) != nil else { return 1.0 }
            return min(max(defaults.double(forKey: Keys.uiScale), uiScaleRange.lowerBound), uiScaleRange.upperBound)
        }
        set { defaults.set(min(max(newValue, uiScaleRange.lowerBound), uiScaleRange.upperBound), forKey: Keys.uiScale) }
    }

    /// Global window opacity (Appearance → Transparency). Default 1.0 = fully opaque.
    static let uiOpacityRange: ClosedRange<Double> = 0.35...1.0
    static var uiOpacity: Double {
        get {
            guard defaults.object(forKey: Keys.uiOpacity) != nil else { return 1.0 }
            return min(max(defaults.double(forKey: Keys.uiOpacity), uiOpacityRange.lowerBound), uiOpacityRange.upperBound)
        }
        set { defaults.set(min(max(newValue, uiOpacityRange.lowerBound), uiOpacityRange.upperBound), forKey: Keys.uiOpacity) }
    }

    /// Frosted-glass window backgrounds (Appearance → Frost). When on, panels and
    /// windows blur the desktop behind them (`.behindWindow` visual effect) instead
    /// of just fading. Default false. Disabled at runtime when system "Reduce
    /// transparency" is on (see `ThemeStore.effectiveFrost`).
    static var uiFrost: Bool {
        get { defaults.bool(forKey: Keys.uiFrost) }
        set { defaults.set(newValue, forKey: Keys.uiFrost) }
    }

    /// Which screen the command runner and Clipboard History open on. Default
    /// `.cursorScreen` (follow the pointer, like Raycast/Ditto).
    static var runnerPlacement: RunnerPlacement {
        get { RunnerPlacement(rawValue: defaults.string(forKey: Keys.runnerPlacement) ?? "") ?? .cursorScreen }
        set { defaults.set(newValue.rawValue, forKey: Keys.runnerPlacement) }
    }

    /// Optional modifier required during a drag before it will snap. Default `.none`.
    static var dragSnapModifier: DragSnapModifier {
        get { DragSnapModifier(rawValue: defaults.string(forKey: Keys.dragSnapModifier) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Keys.dragSnapModifier) }
    }

    static let dragSnapEdgeMarginRange: ClosedRange<Double> = 4...40
    static let dragSnapCornerSizeRange: ClosedRange<Double> = 30...160

    /// How far in from a screen edge (px) the cursor triggers an edge snap. Default 8.
    static var dragSnapEdgeMargin: CGFloat {
        get {
            let v = defaults.object(forKey: Keys.dragSnapEdgeMargin) as? Double ?? 8
            return CGFloat(min(max(v, dragSnapEdgeMarginRange.lowerBound), dragSnapEdgeMarginRange.upperBound))
        }
        set { defaults.set(Double(newValue), forKey: Keys.dragSnapEdgeMargin) }
    }

    /// Side length (px) of the corner squares that snap to quarters. Default 70.
    static var dragSnapCornerSize: CGFloat {
        get {
            let v = defaults.object(forKey: Keys.dragSnapCornerSize) as? Double ?? 70
            return CGFloat(min(max(v, dragSnapCornerSizeRange.lowerBound), dragSnapCornerSizeRange.upperBound))
        }
        set { defaults.set(Double(newValue), forKey: Keys.dragSnapCornerSize) }
    }

    /// Bundle ids of apps that misbehave with AX-driven resize; drag-snap skips them.
    /// Seeded with the usual offenders; user-editable in Settings.
    static let dragSnapDefaultIgnoredBundleIds = [
        "com.mathworks.matlab",
        "com.adobe.illustrator",
        "com.adobe.AfterEffects",
        "com.adobe.Photoshop",
    ]
    static var dragSnapIgnoredBundleIds: [String] {
        get { defaults.object(forKey: Keys.dragSnapIgnoredBundleIds) as? [String] ?? dragSnapDefaultIgnoredBundleIds }
        set { defaults.set(newValue, forKey: Keys.dragSnapIgnoredBundleIds) }
    }

    /// Drag-to-snap behavior: classic edges/corners (default) or drop-into-zone of
    /// the active custom layout. Absence ⇒ `.edges` (unchanged shipping behavior).
    static var snapMode: SnapMode {
        get { SnapMode(rawValue: defaults.string(forKey: Keys.snapMode) ?? "") ?? .edges }
        set { defaults.set(newValue.rawValue, forKey: Keys.snapMode) }
    }

    static let layoutGapRange: ClosedRange<Double> = 0...40

    /// Breathing room (px) between layout zones and the screen edge. Default 8.
    static var layoutGap: CGFloat {
        get {
            let v = defaults.object(forKey: Keys.layoutGap) as? Double ?? 8
            return CGFloat(min(max(v, layoutGapRange.lowerBound), layoutGapRange.upperBound))
        }
        set { defaults.set(Double(newValue), forKey: Keys.layoutGap) }
    }

    /// Persisted custom-layout store. Decode failure or a schema mismatch
    /// (corrupt blob, future version) falls back to built-ins rather than wiping
    /// the feature — a bad read resets to defaults until the next save.
    static var layoutStore: LayoutStore {
        get {
            guard let data = defaults.data(forKey: Keys.layoutStoreJSON),
                  let store = try? JSONDecoder().decode(LayoutStore.self, from: data),
                  store.schemaVersion == LayoutStore.currentSchema else {
                return .builtins
            }
            return store
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            // Data-loss guard: if the stored blob is from a NEWER schema (e.g. a beta
            // build that ran on this machine), this build can't read it and the read
            // path silently falls back to built-ins — overwriting it here would
            // destroy layouts a future/other build owns. Stash the raw bytes once so
            // it can be migrated back, then overwrite. Same-schema saves skip this.
            if let old = defaults.data(forKey: Keys.layoutStoreJSON),
               let v = try? JSONDecoder().decode(SchemaProbe.self, from: old),
               v.schemaVersion > LayoutStore.currentSchema {
                defaults.set(old, forKey: Keys.layoutStoreBackupJSON)
            }
            defaults.set(data, forKey: Keys.layoutStoreJSON)
        }
    }

    /// Menu Bar Management settings (spacing, reveal/hide, reorder). Same
    /// downgrade-safe JSON-in-UserDefaults pattern as `layoutStore`: a corrupt or
    /// newer-schema blob falls back to defaults rather than wiping the feature.
    static var menuBarStore: MenuBarStore {
        get {
            guard let data = defaults.data(forKey: Keys.menuBarStoreJSON),
                  let store = try? JSONDecoder().decode(MenuBarStore.self, from: data),
                  store.schemaVersion == MenuBarStore.currentSchema else {
                return .default
            }
            return store
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            if let old = defaults.data(forKey: Keys.menuBarStoreJSON),
               let v = try? JSONDecoder().decode(SchemaProbe.self, from: old),
               v.schemaVersion > MenuBarStore.currentSchema {
                defaults.set(old, forKey: Keys.menuBarStoreBackupJSON)
            }
            defaults.set(data, forKey: Keys.menuBarStoreJSON)
        }
    }

    /// Menu-bar ordering engine settings (opt-in, desired layout). Separate blob
    /// from `menuBarStore` so the always-on hide/spacing store never carries the
    /// opt-in ordering payload. Same downgrade-safe pattern.
    static var menuBarOrderStore: MenuBarOrderStore {
        get {
            guard let data = defaults.data(forKey: Keys.menuBarOrderStoreJSON),
                  let store = try? JSONDecoder().decode(MenuBarOrderStore.self, from: data),
                  store.schemaVersion == MenuBarOrderStore.currentSchema else {
                return .default
            }
            return store
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            if let old = defaults.data(forKey: Keys.menuBarOrderStoreJSON),
               let v = try? JSONDecoder().decode(SchemaProbe.self, from: old),
               v.schemaVersion > MenuBarOrderStore.currentSchema {
                defaults.set(old, forKey: Keys.menuBarOrderStoreBackupJSON)
            }
            defaults.set(data, forKey: Keys.menuBarOrderStoreJSON)
        }
    }

    /// Minimal envelope to read just `schemaVersion` from a stored blob without
    /// decoding the whole (possibly newer, unknown-shaped) store.
    private struct SchemaProbe: Decodable { var schemaVersion: Int }

    /// Number of tokens the draft model proposes per speculation round. Library
    /// default is 2; small values suit short inline completions where the per-round
    /// verify overhead dominates. `<= 0` falls back to the library default (2).
    static var numDraftTokens: Int {
        get {
            let v = defaults.integer(forKey: Keys.numDraftTokens)
            return v > 0 ? v : 2
        }
        set { defaults.set(newValue, forKey: Keys.numDraftTokens) }
    }

    // Legacy connection constants retained only for the no-op CoreBridge.initialize
    // compatibility shim. The MLX engine has no host/timeout configuration.
    static let coreHost = "http://127.0.0.1:11434"
    static let coreTimeoutMs = 60_000

    /// Bundle ids where inline autocomplete is fully suppressed by default.
    /// Password managers + editors/IDEs (Tab is semantically critical) + system
    /// surfaces where ghost text is unwanted. See docs/FEATURES.md (security).
    static let defaultDisabledBundleIds: Set<String> = [
        "com.bitwarden.desktop",
        "com.apple.Passwords",        // macOS 15+ Passwords app
        "org.keepassxc.keepassxc",
        "com.google.android.studio",
        "com.apple.dt.Xcode",
        "com.apple.finder",
        "com.apple.Preview",
        "com.apple.iCal",             // Calendar
        "com.apple.systempreferences", // System Settings
        // Code editors — Tab/inline completion is semantically owned by the editor.
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        // Command runners / launchers — own their own list UI and key handling.
        "com.raycast.macos",
        "com.runningwithcrows.alfred",
        "com.apple.Spotlight",
    ]

    /// Hugging Face MLX model id used by MLXEngine. Defaults to `defaultModelId`.
    static var coreModel: String {
        get {
            let id = defaults.string(forKey: Keys.coreModel) ?? recommendedModelId
            // Self-heal a selection that the current fork can't load (the pulled 12B/26B).
            return unsupportedModelIds.contains(id) ? recommendedModelId : id
        }
        set { defaults.set(newValue, forKey: Keys.coreModel) }
    }

    /// Hugging Face MLX model id used by the coding agent (a SEPARATE checkpoint
    /// from the inline `coreModel` — bigger, tool-calling-capable, loaded only while
    /// an agent run is active; see ModelResidencyCoordinator). Defaults to
    /// `AgentModelRegistry.recommendedId`. The set of selectable ids lives in
    /// `AgentModelRegistry.models` so adding a model is a one-row change there.
    static var agentModel: String {
        get { defaults.string(forKey: Keys.agentModel) ?? AgentModelRegistry.recommendedId }
        set { defaults.set(newValue, forKey: Keys.agentModel) }
    }

    /// Last working directory chosen for the coding agent. Defaults to the user's
    /// home — the app's `currentDirectoryPath` is `/` when launched as a bundle,
    /// where every command lands outside the sandbox's writable roots.
    static var agentWorkingDirectory: String {
        get { defaults.string(forKey: Keys.agentWorkingDirectory) ?? NSHomeDirectory() }
        set { defaults.set(newValue, forKey: Keys.agentWorkingDirectory) }
    }

    /// Serve dch terminal sessions to the DchTerm app over Tailscale. Off by
    /// default — the server only binds (to the Tailscale interface) when enabled.
    static var remoteTerminalEnabled: Bool {
        get { defaults.bool(forKey: Keys.remoteTerminalEnabled) }
        set { defaults.set(newValue, forKey: Keys.remoteTerminalEnabled) }
    }

    /// Run app-served sessions in a private socket dir (DCH_SOCKET_DIR) so they
    /// do NOT appear in / share with standalone `dch`. Off = shared (the default
    /// the user asked for: terminal-started and app-started sessions intermix).
    static var isolateRemoteSessions: Bool {
        get { defaults.bool(forKey: Keys.isolateRemoteSessions) }
        set { defaults.set(newValue, forKey: Keys.isolateRemoteSessions) }
    }

    /// MCP servers configured for the coding agent. Stored JSON-encoded; an unreadable
    /// or absent value reads as an empty list (no MCP servers, the default).
    static var mcpServers: [MCPServer] {
        get {
            guard let data = defaults.data(forKey: Keys.agentMCPServers),
                  let list = try? JSONDecoder().decode([MCPServer].self, from: data)
            else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.agentMCPServers) }
    }

    /// Lifecycle hooks configured for the coding agent. Stored JSON-encoded; an
    /// unreadable or absent value reads as an empty list (no hooks, the default).
    static var hooks: [HookRule] {
        get {
            guard let data = defaults.data(forKey: Keys.agentHooks),
                  let list = try? JSONDecoder().decode([HookRule].self, from: data)
            else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.agentHooks) }
    }

    /// Selected agent persona id (system-prompt preset). Defaults to the built-in
    /// "build" persona. The chat header can override per session by writing this.
    static var agentPersona: String {
        get { defaults.string(forKey: Keys.agentPersona) ?? "build" }
        set { defaults.set(newValue, forKey: Keys.agentPersona) }
    }

    /// Sampling temperature for the coding agent (0 = deterministic). Defaults to
    /// 0.7. Read per-request by the LLM server, so changes apply on the next turn.
    static var agentTemperature: Double {
        get { defaults.object(forKey: Keys.agentTemperature) as? Double ?? 0.7 }
        set { defaults.set(newValue, forKey: Keys.agentTemperature) }
    }

    /// Nucleus-sampling top-p for the coding agent. Defaults to 1.0 (off).
    static var agentTopP: Double {
        get { defaults.object(forKey: Keys.agentTopP) as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: Keys.agentTopP) }
    }

    /// Bypass-all ("YOLO") permission mode: no approvals + full filesystem access.
    static var agentBypassAll: Bool {
        get { defaults.bool(forKey: Keys.agentBypassAll) }
        set { defaults.set(newValue, forKey: Keys.agentBypassAll) }
    }

    /// codex approval policy when NOT bypassing. Defaults to on-request.
    static var agentApprovalPolicy: String {
        get { defaults.string(forKey: Keys.agentApprovalPolicy) ?? "on-request" }
        set { defaults.set(newValue, forKey: Keys.agentApprovalPolicy) }
    }

    /// Allow the sandboxed agent to reach the network (workspace-write mode).
    static var agentNetworkAccess: Bool {
        get { defaults.bool(forKey: Keys.agentNetworkAccess) }
        set { defaults.set(newValue, forKey: Keys.agentNetworkAccess) }
    }

    /// Extra writable folders granted on top of the working directory (the granular
    /// permission allowlist). Stored as plain paths.
    static var agentWritableRoots: [String] {
        get { defaults.stringArray(forKey: Keys.agentWritableRoots) ?? [] }
        set { defaults.set(newValue, forKey: Keys.agentWritableRoots) }
    }

    /// KV-cache quantization bits for the inline decode path (WS1 memory/speed
    /// lever). `0` = off (full-precision cache, the proven default). Valid library
    /// values are 4 or 8; anything else than {4,8} other than 0 is treated as off.
    static var inlineKVBits: Int {
        get {
            let v = defaults.integer(forKey: Keys.inlineKVBits)
            return (v == 4 || v == 8) ? v : 0
        }
        set { defaults.set(newValue, forKey: Keys.inlineKVBits) }
    }

    static var autocompleteEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.autocompleteEnabled) == nil { return false }
            return defaults.bool(forKey: Keys.autocompleteEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.autocompleteEnabled) }
    }

    /// Whether the coding agent is enabled. When off, its Settings category and
    /// the menu-bar "Coding Agent…" item are hidden. Defaults off so a fresh
    /// install is opt-in.
    static var agentEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.agentEnabled) == nil { return false }
            return defaults.bool(forKey: Keys.agentEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.agentEnabled) }
    }

    /// Whether the System Stats menu-bar monitors are enabled. Off by default —
    /// the whole feature (status items + poller) stays torn down until opted in.
    static var systemStatsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.systemStatsEnabled) == nil { return false }
            return defaults.bool(forKey: Keys.systemStatsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.systemStatsEnabled) }
    }

    /// Base sampling period (seconds) for every System Stats module. Higher = less
    /// CPU. Default 3s (lean to the low side). The poller tiers off this: fast metrics
    /// (CPU/RAM/Net/GPU) sample at this rate, slow ones (temps/power) at half, battery
    /// far slower — so one knob scales the whole cost profile. Clamped 1…10s.
    static var statsRefreshInterval: Double {
        get {
            let v = defaults.object(forKey: Keys.statsRefreshInterval) as? Double ?? 3.0
            return Swift.min(10, Swift.max(1, v))
        }
        set { defaults.set(Swift.min(10, Swift.max(1, newValue)), forKey: Keys.statsRefreshInterval) }
    }

    /// Whether the user has opted into MANUAL fan control. Default OFF — fan writes
    /// go to thermal hardware as root, so nothing touches a fan until this is
    /// explicitly enabled (with a confirmation prompt). Turning it off resets every
    /// fan to OS thermal control.
    static var fanManualEnabled: Bool {
        get { defaults.bool(forKey: Keys.fanManualEnabled) }   // absent → false
        set { defaults.set(newValue, forKey: Keys.fanManualEnabled) }
    }

    /// One-time acknowledgement that the user understands manual fan control writes
    /// hardware as root and can overheat. Once granted, re-engaging manual (e.g.
    /// after toggling back to Automatic) goes straight to the unlock instead of
    /// re-showing the risk prompt every time — consent persists, the per-engage
    /// hardware safety (the thermalmonitord unlock handoff, reset-on-sleep) does not
    /// depend on it.
    static var fanManualConsent: Bool {
        get { defaults.bool(forKey: Keys.fanManualConsent) }   // absent → false
        set { defaults.set(newValue, forKey: Keys.fanManualConsent) }
    }

    /// Saved per-fan manual target RPM, keyed by SMC fan index. Re-applied on launch
    /// and after wake (the daemon never persists fan state — NO save-state on its
    /// side — so the app is the single owner of intent). Stored as a [String: Double]
    /// dictionary in UserDefaults.
    static var fanTargets: [Int: Double] {
        get {
            let raw = defaults.dictionary(forKey: Keys.fanTargets) as? [String: Double] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            defaults.set(raw, forKey: Keys.fanTargets)
        }
    }

    /// Name of the temperature sensor the user pinned as the Sensors headline (menu
    /// bar + popup big readout). nil → auto-pick the hottest live sensor (skipping
    /// static calibration references). Stored by sensor name; an absent/renamed
    /// sensor falls back to auto.
    static var sensorsHeadlineSensor: String? {
        get { defaults.string(forKey: Keys.sensorsHeadlineSensor) }
        set {
            if let v = newValue { defaults.set(v, forKey: Keys.sensorsHeadlineSensor) }
            else { defaults.removeObject(forKey: Keys.sensorsHeadlineSensor) }
        }
    }

    /// Whether Prosper registers as a login item (SMAppService). The actual
    /// registration state is owned by `LaunchAtLogin`; this mirrors user intent.
    static var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: Keys.launchAtLogin) == nil { return true }
            return defaults.bool(forKey: Keys.launchAtLogin)
        }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    /// Max length band for inline completions. Defaults to medium.
    static var completionLength: CompletionLength {
        get {
            guard let raw = defaults.string(forKey: Keys.completionLength),
                  let value = CompletionLength(rawValue: raw) else { return .medium }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.completionLength) }
    }

    /// Modifier for the numbered quick-select shortcuts. Defaults to Command.
    static var quickSelectModifier: QuickSelectModifier {
        get {
            guard let raw = defaults.string(forKey: Keys.quickSelectModifier),
                  let value = QuickSelectModifier(rawValue: raw) else { return .command }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.quickSelectModifier) }
    }

    /// Free-form user instructions appended to the completion system prompt
    /// (tone, language, style). Empty by default.
    static var customInstructions: String {
        get { defaults.string(forKey: Keys.customInstructions) ?? "" }
        set { defaults.set(newValue, forKey: Keys.customInstructions) }
    }

    /// The user's name, woven into the completion system prompt so the model
    /// continues text in the first person where appropriate. Optional; `""`
    /// means unset and contributes nothing. See `structuredPersonaBlock`.
    static var userName: String {
        get { defaults.string(forKey: Keys.userName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.userName) }
    }

    /// The language(s) the user writes in (e.g. "English, Bulgarian"), used to
    /// steer the completion toward the right language/spelling. Optional; `""`
    /// means unset. Free-form so the user can phrase it naturally.
    static var userLanguages: String {
        get { defaults.string(forKey: Keys.userLanguages) ?? "" }
        set { defaults.set(newValue, forKey: Keys.userLanguages) }
    }

    /// The user's preferred voice/tone (e.g. "friendly, professional, concise"),
    /// used to bias the completion's register. Optional; `""` means unset.
    static var voiceStyle: String {
        get { defaults.string(forKey: Keys.voiceStyle) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceStyle) }
    }

    /// A short, structured persona snippet rendered from the *set* personalization
    /// fields (`userName`, `userLanguages`, `voiceStyle`) only — each unset field
    /// is silently skipped. Prepended (ahead of the free-form `customInstructions`
    /// / per-app text) to the addendum that augments the completion system prompt.
    ///
    /// Returns `""` when every field is unset, so the common no-persona path leaves
    /// the system prompt byte-identical to before. Sentences are space-joined into
    /// one compact line, e.g. `"The user's name is Vince. They write in English,
    /// Bulgarian. Preferred voice: concise."`.
    static var structuredPersonaBlock: String {
        var parts: [String] = []
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append("The user's name is \(name).") }
        let langs = userLanguages.trimmingCharacters(in: .whitespacesAndNewlines)
        if !langs.isEmpty { parts.append("They write in \(langs).") }
        let voice = voiceStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voice.isEmpty { parts.append("Preferred voice: \(voice).") }
        return parts.joined(separator: " ")
    }

    /// Bundle ids where autocomplete is suppressed. Seeded with the secure
    /// defaults on first read so users start protected; editable thereafter.
    static var disabledBundleIds: Set<String> {
        get {
            if let stored = defaults.array(forKey: Keys.disabledBundleIds) as? [String] {
                return Set(stored)
            }
            return defaultDisabledBundleIds
        }
        set { defaults.set(Array(newValue), forKey: Keys.disabledBundleIds) }
    }

    /// Bundle ids where the Tab key is never swallowed (suggestions may still
    /// show; accept only via →). Empty by default.
    static var disableTabBundleIds: Set<String> {
        get {
            let stored = defaults.array(forKey: Keys.disableTabBundleIds) as? [String] ?? []
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Keys.disableTabBundleIds) }
    }

    /// Whether inline completions are enabled by default across all apps. When
    /// off, completions show only in apps explicitly added to `enabledBundleIds`
    /// (per-app opt-in). Defaults to true.
    static var completionsEnabledByDefault: Bool {
        get {
            if defaults.object(forKey: Keys.completionsEnabledByDefault) == nil { return true }
            return defaults.bool(forKey: Keys.completionsEnabledByDefault)
        }
        set { defaults.set(newValue, forKey: Keys.completionsEnabledByDefault) }
    }

    /// Bundle ids explicitly opted in when `completionsEnabledByDefault` is off.
    static var enabledBundleIds: Set<String> {
        get {
            let stored = defaults.array(forKey: Keys.enabledBundleIds) as? [String] ?? []
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Keys.enabledBundleIds) }
    }

    /// Whether clipboard text is included as context in the completion prompt.
    static var useClipboardContext: Bool {
        get { defaults.bool(forKey: Keys.useClipboardContext) }
        set { defaults.set(newValue, forKey: Keys.useClipboardContext) }
    }

    /// Whether completions are offered when text exists after the caret
    /// (mid-line). When off, suggestions show only at end-of-line. Default true.
    static var midlineCompletionsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.midlineCompletionsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.midlineCompletionsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.midlineCompletionsEnabled) }
    }

    /// Whether typing `:name` offers an emoji completion. Default true.
    static var emojiSuggestionsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.emojiSuggestionsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.emojiSuggestionsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.emojiSuggestionsEnabled) }
    }

    /// Append a space after accepting the FINAL word of a suggestion with Tab, so
    /// the user can keep typing the next word without pressing Space themselves.
    /// Default false (matches the raw insertion behavior).
    static var trailingSpaceAfterWordAccept: Bool {
        get { defaults.bool(forKey: Keys.trailingSpaceAfterWordAccept) }
        set { defaults.set(newValue, forKey: Keys.trailingSpaceAfterWordAccept) }
    }

    /// Whether to suppress completions when the word at the caret looks
    /// misspelled (NSSpellChecker). Default false.
    static var suppressOnTypo: Bool {
        get { defaults.bool(forKey: Keys.suppressOnTypo) }
        set { defaults.set(newValue, forKey: Keys.suppressOnTypo) }
    }

    /// True if autocomplete should be suppressed for the given bundle id.
    static func isAutocompleteDisabled(forBundleId bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        if disabledBundleIds.contains(bundleId) { return true }
        // Per-app opt-in mode: suppress everywhere except explicitly enabled apps.
        if !completionsEnabledByDefault && !enabledBundleIds.contains(bundleId) {
            return true
        }
        return false
    }

    /// True if Tab must not be swallowed for the given bundle id.
    static func isTabDisabled(forBundleId bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return disableTabBundleIds.contains(bundleId)
    }

    /// Whether to record accepted completions to the local (GRDB) typing-history
    /// store for word-choice personalization. **On by default** (local-only store;
    /// "Delete All" in Settings clears it).
    static var collectTypingHistory: Bool {
        get {
            if defaults.object(forKey: Keys.collectTypingHistory) == nil { return true }
            return defaults.bool(forKey: Keys.collectTypingHistory)
        }
        set { defaults.set(newValue, forKey: Keys.collectTypingHistory) }
    }

    /// How strongly to bias completions toward the user's frequent words
    /// (0 = off … 1 = max). Default 0.5. Only used when `collectTypingHistory` is on.
    static var personalizeWordChoice: Double {
        get {
            if defaults.object(forKey: Keys.personalizeWordChoice) == nil { return 0.5 }
            return defaults.double(forKey: Keys.personalizeWordChoice)
        }
        set { defaults.set(newValue, forKey: Keys.personalizeWordChoice) }
    }

    /// Browser hosts (e.g. `bank.com`) where inline completions are suppressed.
    /// Matched as a suffix so `bank.com` also covers `secure.bank.com`.
    static var disabledDomains: Set<String> {
        get {
            let stored = defaults.array(forKey: Keys.disabledDomains) as? [String] ?? []
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Keys.disabledDomains) }
    }

    /// True if the given browser host is in the disabled-domains list (suffix match).
    static func isDomainDisabled(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        for d in disabledDomains {
            let dom = d.lowercased()
            if host == dom || host.hasSuffix("." + dom) { return true }
        }
        return false
    }

    /// Whether Sparkle checks for updates automatically in the background.
    /// Default true (matches Cotypist); user-controllable in Settings → About.
    static var automaticUpdateChecks: Bool {
        get {
            if defaults.object(forKey: Keys.automaticUpdateChecks) == nil { return true }
            return defaults.bool(forKey: Keys.automaticUpdateChecks)
        }
        set { defaults.set(newValue, forKey: Keys.automaticUpdateChecks) }
    }

    /// Whether the updater also accepts pre-release (beta) builds. Default **false**
    /// — users track the stable channel. When true, Sparkle is allowed the `beta`
    /// appcast channel (see `AppUpdater`/`UpdaterChannelDelegate`), so it picks up
    /// the highest of stable *or* beta. User-controllable in Settings → About.
    static var allowBetaUpdates: Bool {
        get { defaults.bool(forKey: Keys.allowBetaUpdates) } // absent → false
        set { defaults.set(newValue, forKey: Keys.allowBetaUpdates) }
    }

    /// Clipboard history capture. **On by default** (concealed/transient types are
    /// always skipped; disable in Settings → General).
    static var clipboardHistoryEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.clipboardHistoryEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.clipboardHistoryEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.clipboardHistoryEnabled) }
    }

    /// Max retained *unpinned* clipboard entries; oldest evicted beyond this.
    /// **Defaults to 500.** Clamped to a sane range so a stray value can't make
    /// the store unbounded or empty. Pinned entries are exempt from the cap.
    static let clipboardHistoryMaxRange = 10...5000
    static var clipboardHistoryMaxItems: Int {
        get {
            if defaults.object(forKey: Keys.clipboardHistoryMaxItems) == nil { return 500 }
            let v = defaults.integer(forKey: Keys.clipboardHistoryMaxItems)
            return min(max(v, clipboardHistoryMaxRange.lowerBound), clipboardHistoryMaxRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, clipboardHistoryMaxRange.lowerBound),
                              clipboardHistoryMaxRange.upperBound)
            defaults.set(clamped, forKey: Keys.clipboardHistoryMaxItems)
        }
    }

    // MARK: - Snippets

    /// Master switch for the Snippets feature (library + palette + expansion).
    /// **On by default**; the library/palette are passive, and inline expansion is
    /// additionally gated by `snippetsAutoExpand` (off by default).
    static var snippetsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.snippetsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.snippetsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.snippetsEnabled) }
    }

    /// Whether typing a snippet keyword auto-expands it in place, system-wide.
    /// **Off by default** (Alfred parity — opt-in).
    static var snippetsAutoExpand: Bool {
        get { defaults.bool(forKey: Keys.snippetsAutoExpand) }   // absent → false
        set { defaults.set(newValue, forKey: Keys.snippetsAutoExpand) }
    }

    /// When true a keyword fires only after a trailing word-boundary delimiter
    /// (Alfred bare-keyword style). **Off by default** (immediate, Raycast style).
    static var snippetsExpandOnWordBoundary: Bool {
        get { defaults.bool(forKey: Keys.snippetsExpandOnWordBoundary) } // absent → false
        set { defaults.set(newValue, forKey: Keys.snippetsExpandOnWordBoundary) }
    }

    /// Whether the prior clipboard is restored after a paste-based expansion.
    /// **On by default.**
    static var snippetsRestoreClipboard: Bool {
        get {
            if defaults.object(forKey: Keys.snippetsRestoreClipboard) == nil { return true }
            return defaults.bool(forKey: Keys.snippetsRestoreClipboard)
        }
        set { defaults.set(newValue, forKey: Keys.snippetsRestoreClipboard) }
    }

    /// Bundle ids where inline snippet expansion is suppressed. Seeded with the
    /// secure defaults on first read; editable thereafter.
    static var snippetsIgnoredBundleIds: Set<String> {
        get {
            if let stored = defaults.array(forKey: Keys.snippetsIgnoredBundleIds) as? [String] {
                return Set(stored)
            }
            return defaultSnippetsIgnoredBundleIds
        }
        set { defaults.set(Array(newValue), forKey: Keys.snippetsIgnoredBundleIds) }
    }

    // MARK: - Vision / screenshot context

    /// Whether a screenshot of the region around the caret is fed to the model as
    /// extra context (multimodal gemma4 path). **Off by default** (privacy +
    /// requires Screen Recording permission + heavier inference).
    static var useScreenshotContext: Bool {
        get {
            if defaults.object(forKey: Keys.useScreenshotContext) == nil { return true }
            return defaults.bool(forKey: Keys.useScreenshotContext)
        }
        set { defaults.set(newValue, forKey: Keys.useScreenshotContext) }
    }

    /// Whether to sample colors near the caret so the ghost text blends with the
    /// host UI (light/dark adaptation). **On by default** (degrades to nil without
    /// Screen Recording permission).
    static var improveAppearanceFromScreenshot: Bool {
        get {
            if defaults.object(forKey: Keys.improveAppearanceFromScreenshot) == nil { return true }
            return defaults.bool(forKey: Keys.improveAppearanceFromScreenshot)
        }
        set { defaults.set(newValue, forKey: Keys.improveAppearanceFromScreenshot) }
    }

    /// Whether on-screen text near the caret is recognized (Vision/ANE OCR) and fed
    /// to the text model as extra context. Recovers context in Electron/Chromium
    /// apps (Slack, Notion, VS Code) where the Accessibility API exposes little.
    /// Cheaper than the multimodal image path and works with the text-only model.
    /// **Off by default** (privacy + requires Screen Recording permission).
    static var useOCRContext: Bool {
        get {
            if defaults.object(forKey: Keys.useOCRContext) == nil { return true }
            return defaults.bool(forKey: Keys.useOCRContext)
        }
        set { defaults.set(newValue, forKey: Keys.useOCRContext) }
    }

    // MARK: - UI toggles

    /// Whether the menu-bar status icon is shown. Default true. When off the app
    /// keeps running headless (still reachable via hotkeys).
    static var showMenuBarIcon: Bool {
        get {
            if defaults.object(forKey: Keys.showMenuBarIcon) == nil { return true }
            return defaults.bool(forKey: Keys.showMenuBarIcon)
        }
        set { defaults.set(newValue, forKey: Keys.showMenuBarIcon) }
    }

    /// Whether a temporary Dock icon (and Cmd-Tab entry) appears while a Prosper
    /// window is on screen, so backgrounded windows can be switched back to.
    /// Default true. When off the app stays a pure `.accessory` agent (no Dock
    /// tile, not in Cmd-Tab) even with a window open.
    static var showDockIcon: Bool {
        get {
            if defaults.object(forKey: Keys.showDockIcon) == nil { return true }
            return defaults.bool(forKey: Keys.showDockIcon)
        }
        set { defaults.set(newValue, forKey: Keys.showDockIcon) }
    }

    /// Whether a small floating accessory button appears near the active text
    /// field for quick access to the menu. **On by default.**
    static var showAccessoryButton: Bool {
        get {
            if defaults.object(forKey: Keys.showAccessoryButton) == nil { return true }
            return defaults.bool(forKey: Keys.showAccessoryButton)
        }
        set { defaults.set(newValue, forKey: Keys.showAccessoryButton) }
    }

    /// Whether a left mouse click anywhere dismisses the ghost suggestion and
    /// the accessory indicator immediately (the click is about to move focus or
    /// the caret). **On by default.**
    static var dismissOverlaysOnClick: Bool {
        get {
            if defaults.object(forKey: Keys.dismissOverlaysOnClick) == nil { return true }
            return defaults.bool(forKey: Keys.dismissOverlaysOnClick)
        }
        set { defaults.set(newValue, forKey: Keys.dismissOverlaysOnClick) }
    }

    /// Whether suspected typos at the caret are shown struck-through with a
    /// suggested fix beside them (accept replaces the word). **On by default.**
    static var showSuggestedFixes: Bool {
        get {
            if defaults.object(forKey: Keys.showSuggestedFixes) == nil { return true }
            return defaults.bool(forKey: Keys.showSuggestedFixes)
        }
        set { defaults.set(newValue, forKey: Keys.showSuggestedFixes) }
    }

    // MARK: - Emoji presentation

    /// Preferred skin tone applied to skin-tone-capable emoji. Default `.none`.
    static var emojiSkinTone: EmojiSkinTone {
        get {
            guard let raw = defaults.string(forKey: Keys.emojiSkinTone),
                  let v = EmojiSkinTone(rawValue: raw) else { return .none }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.emojiSkinTone) }
    }

    /// Preferred gender for gendered emoji. Default `.male`.
    static var emojiGender: EmojiGender {
        get {
            guard let raw = defaults.string(forKey: Keys.emojiGender),
                  let v = EmojiGender(rawValue: raw) else { return .male }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.emojiGender) }
    }

    // MARK: - Per-app overrides

    /// Bundle ids that use the alternate (clipboard-paste) insertion path for
    /// accepted completions, for apps that mishandle synthesized unicode typing.
    static var improveCompatBundleIds: Set<String> {
        get {
            let stored = defaults.array(forKey: Keys.improveCompatBundleIds) as? [String] ?? []
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Keys.improveCompatBundleIds) }
    }

    /// True if the given bundle id should use the compatibility insertion path.
    static func usesCompatInsertion(forBundleId bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return improveCompatBundleIds.contains(bundleId)
    }

    /// Per-app custom-instruction addenda (bundle id → text), supplementing the
    /// global `customInstructions`.
    static var perAppCustomInstructions: [String: String] {
        get { defaults.dictionary(forKey: Keys.perAppCustomInstructions) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.perAppCustomInstructions) }
    }

    /// Effective custom instructions for a bundle id: global text plus any
    /// per-app addendum (both trimmed; joined with a blank line).
    static func effectiveCustomInstructions(forBundleId bundleId: String?) -> String {
        let global = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleId,
              let perApp = perAppCustomInstructions[bundleId]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !perApp.isEmpty else { return global }
        return global.isEmpty ? perApp : global + "\n\n" + perApp
    }

    // MARK: - Migration flags

    /// True once the one-time migration of ~/Documents/huggingface into
    /// ~/.config/prosper/hf has been attempted. See `ModelPaths.bootstrap()`.
    static var modelDirMigrated: Bool {
        get { defaults.bool(forKey: Keys.modelDirMigrated) }
        set { defaults.set(newValue, forKey: Keys.modelDirMigrated) }
    }

    /// True once the legacy scattered per-app prefs (`perAppCustomInstructions`,
    /// `disabledBundleIds`/`enabledBundleIds`, `disableTabBundleIds`) have been
    /// migrated into the consolidated `AppOverrideStore` (WS3). The legacy accessors
    /// keep working as fallback reads (see `AppOverrideResolver`), so nothing breaks
    /// if migration is skipped or partial.
    static var appOverridesMigrated: Bool {
        get { defaults.bool(forKey: Keys.appOverridesMigrated) }
        set { defaults.set(newValue, forKey: Keys.appOverridesMigrated) }
    }

    /// Per-app "enhanced UI helped" feedback signal (WS4). Maps a bundle id to
    /// `true` once forcing `AXEnhancedUserInterface` / `AXManualAccessibility` on
    /// that app was followed by a successful caret resolution. One boolean per
    /// bundle id, written by `AXEnhancedUI.recordCaretOutcome`; consumed by a
    /// future Settings hint ("forcing enhanced UI likely helped here"). Read-only
    /// signal — it never gates behavior.
    static var enhancedUIHelped: [String: Bool] {
        get { defaults.dictionary(forKey: Keys.enhancedUIHelped) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.enhancedUIHelped) }
    }

    // MARK: - On-device LoRA personalization (WS6)

    /// Master switch for on-device LoRA *training* (WS6). **Off by default.** When
    /// off, no training data is fed to a trainer and `LoRATrainer.train()` returns
    /// `.skipped`. Collection of training samples is gated separately on
    /// `collectTypingHistory` (samples are stored regardless of this flag, so a
    /// later opt-in can train on already-collected accepted completions).
    static var loraEnabled: Bool {
        get { defaults.bool(forKey: Keys.loraEnabled) } // absent → false
        set { defaults.set(newValue, forKey: Keys.loraEnabled) }
    }

    /// Whether a trained LoRA adapter is *served* at inference (WS6). **Off by
    /// default.** When off, `MLXEngine` never loads the adapter and inference is
    /// byte-identical to the base model. Flipped off automatically by the A/B
    /// auto-disable guard when the adapter underperforms the baseline.
    static var loraServingActive: Bool {
        get { defaults.bool(forKey: Keys.loraServingActive) } // absent → false
        set { defaults.set(newValue, forKey: Keys.loraServingActive) }
    }

    /// LoRA rank (adapter bottleneck width). Default 8. `<= 0` falls back to 8.
    static var loraRank: Int {
        get { let v = defaults.integer(forKey: Keys.loraRank); return v > 0 ? v : 8 }
        set { defaults.set(newValue, forKey: Keys.loraRank) }
    }

    /// Number of top transformer layers to attach LoRA to. Default 8. `<= 0` → 8.
    static var loraNumLayers: Int {
        get { let v = defaults.integer(forKey: Keys.loraNumLayers); return v > 0 ? v : 8 }
        set { defaults.set(newValue, forKey: Keys.loraNumLayers) }
    }

    /// Training iterations per `LoRATrainer.train()` run. Default 200. `<= 0` → 200.
    static var loraIterations: Int {
        get { let v = defaults.integer(forKey: Keys.loraIterations); return v > 0 ? v : 200 }
        set { defaults.set(newValue, forKey: Keys.loraIterations) }
    }

    /// Minimum accepted-sample count required before training runs. Default 50.
    /// `<= 0` → 50.
    static var loraMinSamples: Int {
        get { let v = defaults.integer(forKey: Keys.loraMinSamples); return v > 0 ? v : 50 }
        set { defaults.set(newValue, forKey: Keys.loraMinSamples) }
    }

    /// Minimum per-arm shown count before the A/B auto-disable guard can act.
    /// Default 100. `<= 0` → 100.
    static var loraABMinSamples: Int {
        get { let v = defaults.integer(forKey: Keys.loraABMinSamples); return v > 0 ? v : 100 }
        set { defaults.set(newValue, forKey: Keys.loraABMinSamples) }
    }

    /// Timestamp of the last successful LoRA training run, or nil if never trained.
    static var loraLastTrained: Date? {
        get { defaults.object(forKey: Keys.loraLastTrained) as? Date }
        set { defaults.set(newValue, forKey: Keys.loraLastTrained) }
    }

    /// A/B rolling counters: completions shown / accepted while the adapter was
    /// active (`adapter`) vs. while it was inactive / base model (`baseline`).
    /// Used by `LoRAEvaluator` to auto-disable an adapter that underperforms.
    static var loraAdapterShown: Int {
        get { defaults.integer(forKey: Keys.loraAdapterShown) }
        set { defaults.set(newValue, forKey: Keys.loraAdapterShown) }
    }
    static var loraAdapterAccepted: Int {
        get { defaults.integer(forKey: Keys.loraAdapterAccepted) }
        set { defaults.set(newValue, forKey: Keys.loraAdapterAccepted) }
    }
    static var loraBaselineShown: Int {
        get { defaults.integer(forKey: Keys.loraBaselineShown) }
        set { defaults.set(newValue, forKey: Keys.loraBaselineShown) }
    }
    static var loraBaselineAccepted: Int {
        get { defaults.integer(forKey: Keys.loraBaselineAccepted) }
        set { defaults.set(newValue, forKey: Keys.loraBaselineAccepted) }
    }

    // MARK: - Analytics (opt-out)

    /// Whether anonymous, opt-out usage analytics are sent (Aptabase). **On by
    /// default** — the user can disable it in Settings → Analytics, which also shows
    /// the exact payload. Only counters/booleans + an anonymous id are sent; never
    /// PII. See Analytics/AnalyticsService.swift.
    static var analyticsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.analyticsEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.analyticsEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.analyticsEnabled) }
    }

    /// Sanitizes a Hugging Face model id into a single safe path component for the
    /// per-model adapter directory (mirrors the `models--…` blob-dir convention but
    /// flat). E.g. `mlx-community/gemma-4-e2b-it-6bit` → `mlx-community--gemma-4-e2b-it-6bit`.
    static func sanitizedModelId(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "--")
    }
}
