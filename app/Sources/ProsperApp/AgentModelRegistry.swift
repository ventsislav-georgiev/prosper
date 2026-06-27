import Foundation

/// How a model emits tool calls in its decoded text. Keys the server-side
/// `ToolCallParser` (see ProsperLLMServer): mlx-swift-lm has no grammar-constrained
/// decoding, so the OpenAI-compatible endpoint must parse each family's native
/// tool-call syntax out of the raw token stream and re-emit it as OpenAI `tool_calls`.
enum ToolCallFormat: String, Sendable, Codable, CaseIterable {
    /// Qwen3 / Qwen3-Coder: `<tool_call>…</tool_call>` blocks. Body is `{json}`
    /// (Qwen3) or the xml_function `<function=name><parameter=…>` form (Qwen3-Coder).
    case qwenXML
    /// gpt-oss: harmony channels (`analysis` / `commentary` / `final`); tool calls
    /// arrive in the commentary channel, the user-visible answer in `final`.
    case harmony
    /// Hermes-style: bare `<tool_call>…</tool_call>` JSON (Nous/OpenHermes lineage).
    case hermesJSON
    /// Mistral / Devstral: `[TOOL_CALLS]` token + JSON array.
    case mistral
    /// NVIDIA Nemotron-3: `<toolcall>{json}</toolcall>` (lowercase, no underscore),
    /// reasoning wrapped in `<think>…</think>` that must be stripped.
    case nemotron
    /// GLM (Zhipu) 4.x/5: `<tool_call>NAME<arg_key>k</arg_key><arg_value>v</arg_value>…</tool_call>`
    /// (also tolerates the Qwen-compat `<tool_call>{json}</tool_call>` body).
    case glm
    /// Kimi K2 (Moonshot, DeepSeek-V3 arch): token-delimited section
    /// `<|tool_calls_section_begin|><|tool_call_begin|>functions.NAME:idx<|tool_call_argument_begin|>{json}<|tool_call_end|>…`.
    case kimi
    /// MiniMax M2: Anthropic-style XML
    /// `<minimax:tool_call><invoke name="fn"><parameter name="p">value</parameter></invoke></minimax:tool_call>`.
    case minimax
}

/// One selectable coding-agent model. The agent ladder is intentionally separate
/// from the inline `Preferences.selectableModelIds` (different sizes, different
/// quality bar, different RAM tiers, loaded only during an agent run).
struct AgentModel: Sendable, Identifiable, Equatable {
    /// Hugging Face `mlx-community` id (also the `id` for SwiftUI lists).
    let id: String
    /// Picker label.
    let label: String
    /// Estimated resident RSS in GB (weights × ~1.15 + working KV/activations).
    /// Drives the tier grouping and the "exceeds installed RAM" soft warning.
    let approxRAMGB: Double
    /// Installed-RAM floor (GB) this model is sane on. Below it the picker warns
    /// (never hard-blocks — power users may still try).
    let minRAMGB: Int
    /// Native tool-call syntax → selects the server-side parser.
    let toolFormat: ToolCallFormat
    /// One-line note shown under the label (tier hint, caveats).
    let note: String
}

/// The agent-model catalog. **Adding a model is a one-row change here.** Prefer
/// DWQ (distillation-trained quant — the MLX QAT-equivalent, loads through the same
/// affine-quant path as the existing Gemma-QAT models with no engine change) and
/// natively-trained low-bit formats (MXFP4) for best quality-per-GB. Ordered by
/// ascending RAM so the picker reads smallest→largest.
enum AgentModelRegistry {
    // CODING-TUNED ONLY. This ladder serves the coding agent — every entry is a
    // code/SWE-tuned model (or a flagship with strong agentic coding). General-
    // purpose models do NOT belong here (the inline-autocomplete role is a separate,
    // gemma4-VLM-only path — see MLXEngine/SettingsWindow — and can't host them
    // either without engine work). Adding a model is a one-row change.
    static let models: [AgentModel] = [
        // ── 16 GB tier ──────────────────────────────────────────────────────
        AgentModel(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit",
            label: "Qwen3.5 4B",
            approxRAMGB: 3, minRAMGB: 16, toolFormat: .qwenXML,
            note: "~3 GB · latest small Qwen · fastest, light but reliable tool-calling"
        ),
        AgentModel(
            id: "mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit",
            label: "Nemotron 3 Nano 4B",
            approxRAMGB: 3, minRAMGB: 16, toolFormat: .nemotron,
            note: "~3 GB · NVIDIA agentic-tuned · fast, reliable tool-calling"
        ),
        AgentModel(
            id: "mlx-community/Qwen3-8B-4bit-DWQ",
            label: "Qwen3 8B",
            approxRAMGB: 5, minRAMGB: 16, toolFormat: .qwenXML,
            note: "DWQ ~5 GB · light, fast, capable tool-calling"
        ),
        AgentModel(
            id: "mlx-community/phi-4-4bit",
            label: "Phi-4 14B",
            approxRAMGB: 9, minRAMGB: 16, toolFormat: .hermesJSON,
            // ponytail: no native tool syntax — relies on the harness tool-instruction
            // prompt steering it into hermes `<tool_call>` form. Verified-experimental;
            // demote to chat-only or drop if it won't emit tool calls reliably.
            note: "~9 GB · MS Phi-4 · strong reasoning · tool-calling experimental"
        ),
        // ── 24 GB tier ──────────────────────────────────────────────────────
        AgentModel(
            id: "mlx-community/Devstral-Small-2507-4bit-DWQ",
            label: "Devstral Small 24B",
            approxRAMGB: 14, minRAMGB: 24, toolFormat: .mistral,
            note: "DWQ ~14 GB · SWE-agent-trained, reliable in loops"
        ),
        // ── 32 GB tier (primary / recommended) ───────────────────────────────
        AgentModel(
            id: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit-dwq-v2",
            label: "Qwen3-Coder 30B-A3B",
            approxRAMGB: 20, minRAMGB: 32, toolFormat: .qwenXML,
            note: "DWQ v2 ~20 GB · coder-tuned MoE (3B active), best small-Mac tool-calling"
        ),
        AgentModel(
            id: "mlx-community/Qwen3.6-35B-A3B-4bit-DWQ",
            label: "Qwen3.6 35B-A3B",
            approxRAMGB: 22, minRAMGB: 32, toolFormat: .qwenXML,
            note: "DWQ ~22 GB · recommended · latest Qwen flagship MoE (3B active), strong agentic coding"
        ),
        AgentModel(
            id: "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
            label: "Nemotron 3 Nano 30B-A3B",
            approxRAMGB: 18, minRAMGB: 32, toolFormat: .nemotron,
            note: "~18 GB · NVIDIA agentic-tuned MoE (3B active)"
        ),
        // ── 64 GB tier (option; unverified on small machines) ─────────────────
        AgentModel(
            id: "mlx-community/Qwen3-Coder-Next-4bit",
            label: "Qwen3-Coder-Next 80B-A3B",
            approxRAMGB: 45, minRAMGB: 64, toolFormat: .qwenXML,
            note: "~45 GB · needs 64 GB · near-frontier agentic coding"
        ),
        AgentModel(
            id: "mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit",
            label: "Llama 4 Scout 17B-16E",
            // Llama 4 has no dedicated tool-call parser case; hermes `<tool_call>`
            // is the closest — tool-calling is experimental (prompt-steered, no
            // native syntax).
            approxRAMGB: 60, minRAMGB: 64, toolFormat: .hermesJSON,
            note: "⚠️ 109B MoE (17B active, 16E) · ~60 GB · needs ≥64 GB · vision stripped (text-only)"
        ),
        // ── Frontier / experimental tier ─────────────────────────────────────
        // ⚠️ Server-class agentic MoE (230B–1T). All are strong at agentic/coding
        // workflows and their architectures DO load in mlx-swift-lm (minimax, mimo,
        // glm4_moe, deepseek_v3=Kimi, nemotron_h — arch-verified), with a matching
        // per-family tool-call parser. The real limit is RAM: each FAR exceeds any
        // Mac even at 4-bit. The RAM gate only soft-warns, so selecting one can
        // trigger a 100–550 GB download that then OOMs. Here for completeness.
        AgentModel(
            id: "lmstudio-community/MiniMax-M2.5-MLX-4bit",
            label: "MiniMax M2.5 (experimental)",
            approxRAMGB: 130, minRAMGB: 128, toolFormat: .minimax,
            note: "⚠️ 230B agentic MoE (10B active) · ~115 GB · needs ≥128 GB"
        ),
        AgentModel(
            id: "inferencerlabs/MiMo-V2.5-Pro-MLX-4.3bit-INF",
            label: "MiMo V2.5 Pro (experimental)",
            approxRAMGB: 180, minRAMGB: 192, toolFormat: .qwenXML,
            note: "⚠️ Xiaomi agentic MoE · ~170 GB · needs ≥192 GB"
        ),
        AgentModel(
            id: "mlx-community/Nemotron-3-Ultra-550B-A55B-4bit",
            label: "Nemotron 3 Ultra 550B (experimental)",
            approxRAMGB: 320, minRAMGB: 512, toolFormat: .nemotron,
            note: "⚠️ 550B agentic MoE · ~300 GB · needs ≥512 GB"
        ),
        AgentModel(
            id: "mlx-community/GLM-5-4bit",
            label: "GLM-5 (experimental)",
            approxRAMGB: 400, minRAMGB: 512, toolFormat: .glm,
            note: "⚠️ 744B agentic MoE · ~380 GB · only a 512 GB Mac Studio fits"
        ),
        AgentModel(
            id: "pipenetwork/Kimi-K2.7-Code-MLX-4bit-hiprec",
            label: "Kimi K2.7 Code (experimental)",
            approxRAMGB: 580, minRAMGB: 512, toolFormat: .kimi,
            note: "⚠️ 1T coder MoE · ~550 GB · exceeds every Mac even at 4-bit"
        ),
    ]

    /// Default agent model: the latest Qwen flagship MoE (Qwen3.6 35B-A3B) — newest
    /// generation, strong agentic coding, fits a 32 GB dev Mac.
    static let recommendedId = "mlx-community/Qwen3.6-35B-A3B-4bit-DWQ"

    /// Built-in catalog plus any user-added (HF-imported) custom models. The single
    /// source the picker, the AI Models pane, and `model(for:)`/`toolFormat(for:)` read,
    /// so a custom model is tool-parsed and RAM-warned exactly like a built-in one.
    /// Built-ins win on id collision: a custom model whose id later ships as a built-in
    /// is dropped, so callers (and `ForEach`) never see a duplicate id.
    static func all() -> [AgentModel] {
        var seen = Set(models.map(\.id))
        let customs = CustomModelStore.asAgentModels().filter { seen.insert($0.id).inserted }
        return models + customs
    }

    /// Lookup by id (built-in + custom); falls back to the recommended model for an
    /// unknown/removed id.
    static func model(for id: String) -> AgentModel {
        let everything = all()
        return everything.first { $0.id == id }
            ?? everything.first { $0.id == recommendedId }
            ?? models[0]
    }

    /// Tool-call format for an id (recommended model's format if unknown).
    static func toolFormat(for id: String) -> ToolCallFormat {
        model(for: id).toolFormat
    }
}
