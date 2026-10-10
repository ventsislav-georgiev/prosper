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

/// A single-file GGUF build served by the llama.cpp agent engine
/// (`LlamaAgentEngine`) instead of MLX. Rows carrying one get grammar-locked
/// tool calls, q8_0 KV + flash attention, and prompt-prefix KV reuse.
struct AgentGGUF: Sendable, Equatable {
    /// On-disk name under `Prosper/models/gguf/`.
    let fileName: String
    /// Direct single-file download (verified 200, ungated).
    let downloadURL: URL
    /// Exact size in bytes (drives download progress + disk-state display).
    let bytes: Int64
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
    /// Non-nil → this row runs on the llama.cpp engine (`LlamaAgentEngine`)
    /// from this GGUF file; nil → MLX (Hugging Face snapshot) as before.
    var gguf: AgentGGUF? = nil
}

/// The agent-model catalog. **Adding a model is a one-row change here.**
/// GGUF/llama.cpp ONLY — the coding agent went all-in on `LlamaAgentEngine`
/// (grammar-locked tool calls, q8_0 KV + flash attention, prompt-prefix KV
/// reuse). The former MLX built-in ladder was removed (git history has it);
/// MLX survives only for user-imported HF custom models (`CustomModelStore`),
/// which still route to `MLXEngine`. Ordered by ascending RAM.
enum AgentModelRegistry {
    // CODING-TUNED ONLY. This ladder serves the coding agent — every entry is a
    // code/SWE-tuned model (or a flagship with strong agentic coding). General-
    // purpose models do NOT belong here (the inline-autocomplete role is a separate,
    // gemma-only llama.cpp path — see LlamaInlineEngine). Qwen-only for now
    // (`LlamaAgentEngine` hand-renders the ChatML template).
    static let models: [AgentModel] = [
        AgentModel(
            id: "unsloth/Qwen3.5-4B-GGUF",
            label: "Qwen3.5 4B (llama.cpp)",
            approxRAMGB: 3.5, minRAMGB: 16, toolFormat: .qwenXML,
            note: "GGUF Q4_K_M ~2.6 GB · llama.cpp · grammar-locked tool calls, fastest",
            gguf: AgentGGUF(
                fileName: "Qwen3.5-4B-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!,
                bytes: 2_740_937_888)
        ),
        // Nemotron 3 Nano: template verified exact ChatML (`<|im_start|>role\n…`,
        // `<tool_response>` user blocks) with `<tool_call><function=…>` calls — the
        // qwenXML parser's xml_function branch. Renders through the same
        // `renderChatML`, no engine change.
        AgentModel(
            id: "unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF",
            label: "Nemotron 3 Nano 4B (llama.cpp)",
            approxRAMGB: 3.5, minRAMGB: 16, toolFormat: .qwenXML,
            note: "GGUF Q4_K_M ~2.7 GB · NVIDIA agentic-tuned · fast",
            gguf: AgentGGUF(
                fileName: "NVIDIA-Nemotron-3-Nano-4B-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF/resolve/8e81be55c5aa3d63bb82b6ceec62d50805d9e1bb/NVIDIA-Nemotron-3-Nano-4B-Q4_K_M.gguf")!,
                bytes: 2_900_295_712)
        ),
        // Qwen3.5 9B: GGUF chat template byte-identical to the Qwen3.5-4B row's.
        // URL pinned to a commit sha (same policy as the inline catalog, #160).
        AgentModel(
            id: "unsloth/Qwen3.5-9B-GGUF",
            label: "Qwen3.5 9B (llama.cpp)",
            approxRAMGB: 7, minRAMGB: 16, toolFormat: .qwenXML,
            note: "GGUF Q4_K_M ~5.7 GB · llama.cpp · grammar-locked tool calls",
            gguf: AgentGGUF(
                fileName: "Qwen3.5-9B-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/Qwen3.5-9B-Q4_K_M.gguf")!,
                bytes: 5_680_522_464)
        ),
        // Nemotron 3.5 Lightning: same ChatML skeleton, `<tool_response>` blocks,
        // `<tool_call><function=…>` calls and generation prompt as the Nemotron 3
        // Nano template it replaces (diff = Unsloth Jinja fixes + reasoning-history
        // whitespace, neither reaches `renderChatML`). Unsloth ships only UD-Q4_K_M
        // at this tier. URL pinned to a commit sha.
        AgentModel(
            id: "unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF",
            label: "Nemotron 3.5 Lightning 30B-A3B (llama.cpp)",
            approxRAMGB: 27, minRAMGB: 32, toolFormat: .qwenXML,
            note: "GGUF UD-Q4_K_M ~25 GB · NVIDIA agentic MoE (3B active)",
            gguf: AgentGGUF(
                fileName: "NVIDIA-Nemotron-3.5-Lightning-30B-A3B-UD-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF/resolve/f2d3fe3694501008786e81e5f20360cbf715496a/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-UD-Q4_K_M.gguf")!,
                bytes: 25_266_255_936)
        ),
        AgentModel(
            id: "unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF",
            label: "Qwen3-Next 80B-A3B (llama.cpp)",
            approxRAMGB: 50, minRAMGB: 64, toolFormat: .qwenXML,
            note: "GGUF Q4_K_M ~45 GB · needs 64 GB · hybrid-attention flagship MoE (3B active)",
            gguf: AgentGGUF(
                fileName: "Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF/resolve/6688872b7a4e5eb8a121ceea08009530a024ba1d/Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf")!,
                bytes: 48_506_100_512)
        ),
        AgentModel(
            id: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
            label: "Qwen3-Coder 30B-A3B (llama.cpp)",
            approxRAMGB: 20, minRAMGB: 32, toolFormat: .qwenXML,
            note: "GGUF Q4_K_M ~17 GB · recommended · coder MoE (3B active), grammar-locked tool calls",
            gguf: AgentGGUF(
                fileName: "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/b17cb02dd882d5b6ab62fc777ad2995f19668350/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf")!,
                bytes: 18_556_689_568)
        ),
        AgentModel(
            id: "unsloth/Qwen3.6-35B-A3B-GGUF",
            label: "Qwen3.6 35B-A3B (llama.cpp)",
            approxRAMGB: 24, minRAMGB: 32, toolFormat: .qwenXML,
            note: "GGUF UD-Q4_K_M ~22 GB · newest Qwen MoE (3B active), grammar-locked tool calls",
            gguf: AgentGGUF(
                fileName: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf")!,
                bytes: 22_134_528_992)
        ),
        AgentModel(
            id: "unsloth/Qwen3-Coder-Next-GGUF",
            label: "Qwen3-Coder-Next 80B-A3B (llama.cpp)",
            approxRAMGB: 50, minRAMGB: 64, toolFormat: .qwenXML,
            note: "GGUF Q4_K_M ~45 GB · needs 64 GB · near-frontier agentic coding",
            gguf: AgentGGUF(
                fileName: "Qwen3-Coder-Next-Q4_K_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF/resolve/ce09c67b53bc8739eef83fe67b2f5d293c270632/Qwen3-Coder-Next-Q4_K_M.gguf")!,
                bytes: 48_528_320_544)
        ),
    ]

    /// Default agent model: Qwen3-Coder 30B-A3B on the llama.cpp engine —
    /// coder-tuned MoE that fits a 32 GB dev Mac, with grammar-locked tool
    /// calls and prompt-prefix KV reuse (the fastest correct agent path).
    static let recommendedId = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"

    /// Built-in catalog plus any user-added (HF-imported) custom models. The single
    /// source the picker, the AI Models pane, and `model(for:)`/`toolFormat(for:)` read,
    /// so a custom model is tool-parsed and RAM-warned exactly like a built-in one.
    /// Built-ins win on id collision: a custom model whose id later ships as a built-in
    /// is dropped, so callers (and `ForEach`) never see a duplicate id.
    static func all() -> [AgentModel] {
        var seen = Set(models.map(\.id))
        let customs = CustomModelStore.asAgentModels().filter { seen.insert($0.id).inserted }
        // Sort smallest→largest by RAM so the picker reads top-down by size and
        // custom (HF-imported) models slot into the right tier instead of trailing
        // the list. Stable tie-break on id keeps equal-RAM rows deterministic.
        return (models + customs).sorted { ($0.approxRAMGB, $0.id) < ($1.approxRAMGB, $1.id) }
    }

    /// Ids retired from the catalog → the row that replaced them (#159), so a saved
    /// pick lands on its same-RAM-tier successor instead of the 32 GB recommended.
    static let replacements: [String: String] = [
        "unsloth/Qwen3-8B-GGUF": "unsloth/Qwen3.5-9B-GGUF",
        "unsloth/Nemotron-3-Nano-30B-A3B-GGUF": "unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF",
    ]

    /// The one self-heal for a saved agent id: known (built-in or custom) → itself,
    /// retired → its replacement, anything else → `recommendedId`. Both
    /// `Preferences.agentModel` and `model(for:)` route through here.
    static func canonicalId(_ id: String) -> String {
        let ids = Set(all().map(\.id))
        if ids.contains(id) { return id }
        if let r = replacements[id], ids.contains(r) { return r }
        return recommendedId
    }

    /// Lookup by id (built-in + custom); a removed id resolves via `canonicalId`.
    static func model(for id: String) -> AgentModel {
        let everything = all()
        let id = canonicalId(id)
        return everything.first { $0.id == id } ?? models[0]
    }

    /// Tool-call format for an id (recommended model's format if unknown).
    static func toolFormat(for id: String) -> ToolCallFormat {
        model(for: id).toolFormat
    }

    /// GGUF spec for an id — EXACT match only. This routes *engine selection*
    /// (`ModelResidencyCoordinator`), where `model(for:)`'s recommended-fallback
    /// would silently swap an unknown MLX id onto the llama engine.
    static func gguf(for id: String) -> AgentGGUF? {
        models.first { $0.id == id }?.gguf
    }
}
