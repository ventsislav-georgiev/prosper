import Foundation
import MLXLMCommon
import llama

// MARK: - Engine abstraction

/// What `ProsperLLMServer` needs from a chat engine: stream raw decoded text for a
/// rendered conversation. Tool-call *parsing* stays in the server (`ToolCallParser`),
/// so both engines produce the same bytes-level contract and the whole
/// validate/repair pipeline is engine-agnostic.
protocol AgentChatEngine: Sendable {
    nonisolated func generateChat(
        messages: [MLXEngine.ChatTurn],
        tools: [ToolSpec],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stop: [String]
    ) -> AsyncThrowingStream<String, Error>

    /// Free the model weights (agent mode released).
    func unload() async
}

/// MLX side of the abstraction. The concrete `generateChat` carries extra
/// defaulted parameters (`repetitionPenalty`), and defaulted parameters don't
/// satisfy a protocol requirement — this exact-signature wrapper does.
extension MLXEngine: AgentChatEngine {
    nonisolated func generateChat(
        messages: [ChatTurn], tools: [ToolSpec], maxTokens: Int,
        temperature: Float, topP: Float, stop: [String]
    ) -> AsyncThrowingStream<String, Error> {
        generateChat(
            messages: messages, tools: tools, maxTokens: maxTokens,
            temperature: temperature, topP: topP,
            repetitionPenalty: nil, stop: stop)
    }
}

// MARK: - GGUF download (shared by inline + agent engines)

/// Plain single-file GGUF fetch with byte progress. Extracted from
/// `LlamaInlineEngine.downloadModel` so the agent engine reuses it.
enum GGUFDownload {
    enum DownloadError: Error { case failed(String) }

    static func fetch(
        url: URL, dest: URL, expectedBytes: Int64,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            progress(1.0, "Downloaded.")
            return
        }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        final class TaskBox: @unchecked Sendable { var task: URLSessionDownloadTask? }
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                    if let err { cont.resume(throwing: err); return }
                    guard let tmp,
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
                    else {
                        cont.resume(throwing: DownloadError.failed("model download failed"))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        cont.resume()
                    } catch { cont.resume(throwing: error) }
                }
                box.task = task
                // Progress poll off the delegate (closure-based task has none).
                Task {
                    while task.state == .running || task.state == .suspended {
                        let got = task.countOfBytesReceived
                        let total = task.countOfBytesExpectedToReceive > 0
                            ? task.countOfBytesExpectedToReceive : expectedBytes
                        if got > 0 {
                            let mb = Double(got) / 1_048_576
                            progress(min(Double(got) / Double(total), 0.99),
                                     String(format: "Downloading model… %.0f MB", mb))
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                task.resume()
            }
            progress(1.0, "Downloaded.")
        } onCancel: {
            box.task?.cancel()
        }
    }
}

// MARK: - llama.cpp agent chat engine

/// Coding-agent chat engine on llama.cpp — the same engine family that already
/// serves inline autocomplete (`LlamaInlineEngine`), applied to the agent's long
/// multi-turn prompts. What it buys over the MLX chat path:
///
///   * **prompt-prefix KV reuse** with `llama_memory_seq_rm` trims — codex turns
///     are append-only, so each turn re-prefills only its new tail (same scheme
///     as `MLXEngine.streamChat`, cheaper trims),
///   * **quantized KV (q8_0) + flash attention** — agent contexts run tens of
///     thousands of tokens where fp16 KV is multi-GB and decode is
///     bandwidth-bound,
///   * **grammar-constrained tool calls** (lazy GBNF, `<tool_call>`-triggered) —
///     a malformed tool call becomes structurally impossible, so the server's
///     repair ladder (a full re-decode per repair) never fires.
///
/// Scope: Qwen-family GGUFs (ChatML template, `qwenXML` tool syntax) — the
/// catalog gate in `AgentModelRegistry`. Other families need their own template
/// rendering before joining.
actor LlamaAgentEngine: AgentChatEngine {
    static let shared = LlamaAgentEngine()

    enum EngineError: Error, LocalizedError {
        case modelMissing(String)
        case loadFailed(String)
        case promptTooLong(tokens: Int, ctx: Int)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .modelMissing(let p): return "agent model file missing: \(p)"
            case .loadFailed(let m): return m
            case .promptTooLong(let t, let c):
                return "agent prompt (\(t) tokens) exceeds the context window (\(c))"
            case .decodeFailed: return "llama_decode failed"
            }
        }
    }

    /// Context window. Codex compacts its history well below this; the ceiling
    /// exists so KV memory stays bounded (q8_0 keeps it modest).
    static var contextTokens: Int {
        Int(ProcessInfo.processInfo.environment["PROSPER_AGENT_NCTX"] ?? "") ?? 40960
    }

    /// q8_0 KV + flash attention by default; `PROSPER_AGENT_KV=f16` reverts.
    static var quantizedKV: Bool {
        ProcessInfo.processInfo.environment["PROSPER_AGENT_KV"] != "f16"
    }

    /// Lazy GBNF tool-call grammar; `PROSPER_AGENT_GRAMMAR=0` disables.
    static var grammarEnabled: Bool {
        ProcessInfo.processInfo.environment["PROSPER_AGENT_GRAMMAR"] != "0"
    }

    private static var timingEnabled: Bool {
        ProcessInfo.processInfo.environment["PROSPER_AGENT_TIMING"] != nil
    }

    /// Where agent GGUFs land (same tree as the inline engine's).
    static func fileURL(fileName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Prosper/models/gguf/\(fileName)")
    }

    // MARK: state

    /// Weight bytes of the resident GGUF (0 when unloaded) — the MLX allocator
    /// can't see llama.cpp memory, so the AI Models pane reads this instead.
    nonisolated(unsafe) private(set) static var residentBytesSnapshot: Int64 = 0

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var batch: llama_batch?
    private var loadedFileName: String?
    /// Tokens materialized in seq 0's KV (prompt-prefix reuse across turns).
    private var cachedPromptTokens: [llama_token] = []

    // MARK: lifecycle

    /// Download (if needed) and load `spec`. Idempotent per file; switching
    /// models unloads the previous one first (swap-not-add memory rule).
    func ensureModel(
        _ spec: AgentGGUF,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        if loadedFileName == spec.fileName, ctx != nil { return }
        unloadLocked()
        let dest = Self.fileURL(fileName: spec.fileName)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try await GGUFDownload.fetch(
                url: spec.downloadURL, dest: dest, expectedBytes: spec.bytes, progress: progress)
        }
        progress(0.99, "Loading model…")
        try load(path: dest.path)
        loadedFileName = spec.fileName
        progress(1.0, "Ready.")
    }

    private func load(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.modelMissing(path)
        }
        llama_backend_init()
        llama_log_set({ level, text, _ in
            if level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text {
                NSLog("llama-agent: %@", String(cString: text))
            }
        }, nil)
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(path, mparams) else {
            throw EngineError.loadFailed("agent model load failed: \(path)")
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(Self.contextTokens)
        cparams.n_batch = 2048
        cparams.n_ubatch = 512
        cparams.n_seq_max = 1
        if Self.quantizedKV {
            // V-cache quantization requires flash attention — enable explicitly
            // (AUTO can resolve to disabled on some models, which then rejects
            // the quantized V cache at init).
            cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
            cparams.type_k = GGML_TYPE_Q8_0
            cparams.type_v = GGML_TYPE_Q8_0
        }
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw EngineError.loadFailed("agent context init failed (ctx=\(Self.contextTokens))")
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        batch = llama_batch_init(2048, 0, 1)
        cachedPromptTokens = []
        Self.residentBytesSnapshot = Int64(llama_model_size(m))
        NSLog("prosper agent: llama engine loaded (%@, n_ctx=%d, kv=%@)",
              (path as NSString).lastPathComponent, Self.contextTokens,
              Self.quantizedKV ? "q8_0+fa" : "f16")
    }

    func unload() {
        unloadLocked()
    }

    private func unloadLocked() {
        Self.residentBytesSnapshot = 0
        if let batch { llama_batch_free(batch) }
        batch = nil
        if let ctx { llama_free(ctx) }
        ctx = nil
        if let model { llama_model_free(model) }
        model = nil
        vocab = nil
        loadedFileName = nil
        cachedPromptTokens = []
    }

    var isLoaded: Bool { ctx != nil }

    // MARK: tokenize / detokenize

    private func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8)
        var out = [llama_token](repeating: 0, count: utf8.count + 16)
        let n = utf8.withUnsafeBufferPointer { buf in
            llama_tokenize(
                vocab,
                buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                Int32(utf8.count), &out, Int32(out.count), addSpecial, parseSpecial)
        }
        guard n >= 0 else { return [] }
        return Array(out.prefix(Int(n)))
    }

    /// Detokenize WITH special tokens rendered as text: `ToolCallParser` needs
    /// `<tool_call>…</tool_call>` to appear literally in the stream, same as the
    /// MLX path's raw-token detokenization.
    private func pieceBytes(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 128)
        var t = token
        let n = withUnsafePointer(to: &t) { tp in
            llama_detokenize(vocab, tp, 1, &buf, Int32(buf.count), false, true)
        }
        return n >= 0 ? buf.prefix(Int(n)).map { UInt8(bitPattern: $0) } : []
    }

    // MARK: prompt rendering (ChatML / Qwen)

    /// Render the conversation through the Qwen ChatML template, injecting tool
    /// signatures into the system turn in the model's trained format (the JSON
    /// `<tool_call>` body form — `ToolCallParser.qwenXML` accepts it alongside
    /// the coder XML form). Tool-result turns render as `<tool_response>` user
    /// blocks, exactly as Qwen's own Jinja template does.
    static func renderChatML(messages: [MLXEngine.ChatTurn], tools: [ToolSpec]) -> String {
        var msgs = messages
        let toolsBlock = toolsSystemBlock(tools)
        if !toolsBlock.isEmpty {
            if let i = msgs.firstIndex(where: { $0.role == "system" }) {
                msgs[i] = MLXEngine.ChatTurn(
                    role: "system", content: msgs[i].content + "\n\n" + toolsBlock)
            } else {
                msgs.insert(MLXEngine.ChatTurn(role: "system", content: toolsBlock), at: 0)
            }
        }
        var out = ""
        for m in msgs {
            switch m.role {
            case "tool":
                out += "<|im_start|>user\n<tool_response>\n\(m.content)\n</tool_response><|im_end|>\n"
            case "system", "user", "assistant":
                out += "<|im_start|>\(m.role)\n\(m.content)<|im_end|>\n"
            default:
                out += "<|im_start|>user\n\(m.content)<|im_end|>\n"
            }
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    /// The Qwen3 tools preamble (verbatim from the family's chat template).
    static func toolsSystemBlock(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        let signatures = tools.compactMap { t -> String? in
            let dict = t.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        return """
        # Tools

        You may call one or more functions to assist with the user query.

        You are provided with function signatures within <tools></tools> XML tags:
        <tools>
        \(signatures)
        </tools>

        For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
        <tool_call>
        {"name": <function-name>, "arguments": <args-json-object>}
        </tool_call>
        """
    }

    // MARK: tool-call grammar (lazy GBNF)

    /// GBNF for the Qwen JSON tool-call form, constrained to the request's tool
    /// names with generic-JSON arguments. Lazily triggered on `<tool_call>`, so
    /// prose streams unconstrained and a malformed call (bad JSON, unknown tool,
    /// unclosed block) becomes structurally impossible — the server's repair
    /// ladder never fires on the llama path. Argument *types* still go through
    /// `SchemaValidator` (generic-JSON grammar keeps this simple and robust).
    static func toolCallGrammar(toolNames: [String]) -> String? {
        guard !toolNames.isEmpty else { return nil }
        // Tool names come from the harness (identifier-like); refuse to build a
        // grammar around one that could break out of a GBNF string literal.
        let safe = toolNames.filter { $0.allSatisfy { c in c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." } }
        guard safe.count == toolNames.count else { return nil }
        let names = safe.map { #""\"\#($0)\"""# }.joined(separator: " | ")
        return #"""
        root ::= block ( nl block )* nl?
        block ::= "<tool_call>" ws "{" ws "\"name\"" ws ":" ws name ws "," ws "\"arguments\"" ws ":" ws object ws "}" ws "</tool_call>"
        name ::= \#(names)
        object ::= "{" ws ( member ( ws "," ws member )* )? ws "}"
        member ::= string ws ":" ws value
        value ::= object | array | string | number | "true" | "false" | "null"
        array ::= "[" ws ( value ( ws "," ws value )* )? ws "]"
        string ::= "\"" char* "\""
        char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt/] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
        number ::= "-"? ([0-9] | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
        ws ::= [ \t\n]*
        nl ::= "\n"
        """#
    }

    // MARK: generation

    nonisolated func generateChat(
        messages: [MLXEngine.ChatTurn],
        tools: [ToolSpec],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stop: [String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(
                        messages: messages, tools: tools, maxTokens: maxTokens,
                        temperature: temperature, topP: topP, stop: stop,
                        continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        messages: [MLXEngine.ChatTurn],
        tools: [ToolSpec],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stop: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        guard let ctx, var batch, let vocab else {
            throw EngineError.loadFailed("agent model not loaded")
        }
        let mem = llama_get_memory(ctx)
        let nCtx = Int(llama_n_ctx(ctx))

        let prompt = Self.renderChatML(messages: messages, tools: tools)
        let promptTokens = tokenize(prompt, addSpecial: true, parseSpecial: true)
        guard !promptTokens.isEmpty else { return }
        guard promptTokens.count + 16 < nCtx else {
            throw EngineError.promptTooLong(tokens: promptTokens.count, ctx: nCtx)
        }
        if Task.isCancelled { return }

        // ---- prompt-prefix KV reuse (the streamChat scheme, llama flavor)
        var lcp = 0
        while lcp < cachedPromptTokens.count, lcp < promptTokens.count,
              cachedPromptTokens[lcp] == promptTokens[lcp] { lcp += 1 }
        // Keep at least one token to prefill so the final decode row has logits.
        let keep = min(lcp, promptTokens.count - 1)
        llama_memory_seq_rm(mem, 0, llama_pos(keep), -1)
        cachedPromptTokens = Array(promptTokens.prefix(keep))
        let t0 = DispatchTime.now()

        func batchClear() { batch.n_tokens = 0 }
        func batchAdd(_ token: llama_token, pos: Int32, logits: Bool) {
            let i = Int(batch.n_tokens)
            batch.token[i] = token
            batch.pos[i] = pos
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = logits ? 1 : 0
            batch.n_tokens += 1
        }

        // Chunked prefill of the divergent suffix.
        var idx = keep
        while idx < promptTokens.count {
            let end = min(idx + 2048, promptTokens.count)
            batchClear()
            for p in idx..<end {
                batchAdd(promptTokens[p], pos: Int32(p), logits: p == promptTokens.count - 1)
            }
            guard llama_decode(ctx, batch) == 0 else {
                cachedPromptTokens = []
                llama_memory_seq_rm(mem, 0, 0, -1)
                throw EngineError.decodeFailed
            }
            cachedPromptTokens.append(contentsOf: promptTokens[idx..<end])
            idx = end
            if Task.isCancelled { return }
        }

        // ---- sampler chain (per request; freed with the chain)
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        if Self.grammarEnabled, !tools.isEmpty {
            let names = tools.compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String }
            if let grammar = Self.toolCallGrammar(toolNames: names) {
                // Trigger on the model's native `<tool_call>` special token; if the
                // vocab doesn't have it as a single token, skip the grammar (the
                // repair ladder remains as the backstop).
                let trigger = tokenize("<tool_call>", addSpecial: false, parseSpecial: true)
                if trigger.count == 1 {
                    var triggerTokens = trigger
                    let sampler = grammar.withCString { g in
                        "root".withCString { r in
                            llama_sampler_init_grammar_lazy_patterns(
                                vocab, g, r, nil, 0, &triggerTokens, 1)
                        }
                    }
                    if let sampler { llama_sampler_chain_add(chain, sampler) }
                }
            }
        }
        if temperature <= 0.01 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if topP < 1.0 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1)) }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(0x50524F53))
        }

        // ---- decode loop
        var utf8 = UTF8Assembler()
        var emitted = ""
        var emittedCount = 0
        var sentCount = 0
        let maxStopLen = stop.lazy.map { $0.count }.max() ?? 0
        var generated = 0
        var pos = Int32(promptTokens.count)
        let budget = min(maxTokens, nCtx - promptTokens.count - 1)

        decode: while generated < budget {
            if Task.isCancelled { break }
            let token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            batchClear()
            batchAdd(token, pos: pos, logits: true)
            guard llama_decode(ctx, batch) == 0 else {
                cachedPromptTokens = []
                llama_memory_seq_rm(mem, 0, 0, -1)
                throw EngineError.decodeFailed
            }
            cachedPromptTokens.append(token)
            pos += 1
            generated += 1

            let chunk = utf8.push(pieceBytes(token))
            guard !chunk.isEmpty else { continue }
            emitted += chunk
            emittedCount += chunk.count
            // Stop-sequence scan over a bounded tail window (see streamChat).
            if maxStopLen > 0 {
                let windowChars = min(emittedCount, chunk.count + maxStopLen - 1)
                let windowStart = emitted.index(emitted.endIndex, offsetBy: -windowChars)
                var cutAt: String.Index? = nil
                for s in stop where !s.isEmpty {
                    if let r = emitted.range(of: s, range: windowStart..<emitted.endIndex) {
                        if cutAt == nil || r.lowerBound < cutAt! { cutAt = r.lowerBound }
                    }
                }
                if let cutAt {
                    let kept = String(emitted[..<cutAt])
                    if kept.count > sentCount {
                        let start = kept.index(kept.startIndex, offsetBy: sentCount)
                        continuation.yield(String(kept[start...]))
                    }
                    break decode
                }
            }
            continuation.yield(chunk)
            sentCount = emittedCount
        }

        if Self.timingEnabled {
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            NSLog("prosper agent(llama): reused %d/%d prompt tokens, prefilled %d, decoded %d tok in %.0fms",
                  keep, promptTokens.count, promptTokens.count - keep, generated, wallMs)
        }
        // A cancelled stream may have stopped between sample and decode; the
        // cache bookkeeping above only records tokens actually fed, so the
        // prefix stays truthful either way.
    }
}

/// Incremental UTF-8 assembly for per-token byte pieces: emits the longest
/// complete prefix, holding back a trailing partial multi-byte character until
/// its continuation bytes arrive (same contract as MLX's streaming detokenizer).
struct UTF8Assembler {
    private var pending: [UInt8] = []

    mutating func push(_ bytes: [UInt8]) -> String {
        pending += bytes
        var cut = pending.count
        var i = pending.count - 1
        var back = 0
        scan: while i >= 0, back < 4 {
            let b = pending[i]
            if b & 0x80 == 0 { break scan }          // ASCII — complete
            if b & 0xC0 == 0xC0 {                    // lead byte
                let need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : 2)
                if pending.count - i < need { cut = i }
                break scan
            }
            back += 1                                 // continuation byte
            i -= 1
        }
        guard cut > 0 else { return "" }
        let out = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return out
    }
}
