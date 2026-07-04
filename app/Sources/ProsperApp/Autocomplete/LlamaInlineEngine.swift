import Foundation
import Accelerate
import llama

/// Inline completion engine on llama.cpp.
///
/// This is the recovered reference decode machinery, ported faithfully:
///   * instruction/context in the USER turn, the text being continued
///     PREFILLED into the MODEL turn — echo impossible by construction
///   * threshold beam: branch when an alternative token clears BOTH
///     `minBranchProbability` and `relativeCutoff` (p ≥ pMax·cutoff);
///     all live beams advance in ONE `llama_decode` via a multi-sequence
///     `llama_batch`; a fork is `llama_memory_seq_cp` (metadata-only with
///     `kv_unified`) — this multi-seq KV fork is WHY llama.cpp: mlx-swift-lm
///     has no equivalent, a beam there costs width× sequential decodes
///   * rank by average log-softmax per token, clamped at -100
///   * confidence gate: below `minAvgLogprob` NOTHING is suggested — with a
///     beam behind it, "no suggestion" is a legitimate answer instead of the
///     forced greedy junk the banned-EOT single path produced (bench: digit
///     runs on confident-done cases)
///   * byte-level required prefix: the prompt can be frozen at a word
///     boundary and the chars typed since constrain decode byte-by-byte —
///     the KV prefix then stays IDENTICAL while a word is being typed
///
/// Engine scope: INLINE AUTOCOMPLETE ONLY. Agent/chat/VLM stay on MLX; the
/// memory rule is swap-not-add (the MLX inline model is not loaded while this
/// engine is active). Default OFF — see `isEnabled`.
actor LlamaInlineEngine {

    static let shared = LlamaInlineEngine()

    struct Candidate: Sendable {
        let text: String
        let avgLogprob: Float
    }

    struct Params: Sendable {
        /// Beam width (`maxSearchWidth`). Fixed at context init (n_seq_max).
        var searchWidth: Int32 = 6
        /// Absolute branch threshold: an alternative must have p ≥ this.
        var minBranchProbability: Float = 0.10
        /// Relative branch threshold: an alternative must have p ≥ pMax·this.
        var relativeCutoff: Float = 0.30
        /// Decode budget per candidate; the newline stop usually ends earlier.
        var maxNewTokens: Int = 24
        /// Confidence gate (Phase C): candidates with avg logprob below this
        /// are dropped; when none survive, no suggestion is shown.
        /// exp(-1.5) ≈ 0.22 per-token probability.
        var minAvgLogprob: Float = -1.5
        /// Force the first N steps to non-ending tokens (no EOT, no newline).
        /// A chat model reads the prefilled model turn as a finished answer and
        /// ends at step 0 on most inputs (regress: 91/166 empty) — the Phase A
        /// lesson, ported into the beam. Unlike the banned-EOT greedy path this
        /// does NOT force junk into the ghost: the forced continuation still
        /// has to clear `minAvgLogprob`, and a forced low-probability head
        /// drags the average down exactly when the model had nothing to say.
        var minForcedTokens: Int = 3
    }

    enum EngineError: Error {
        case modelMissing(String)
        case loadFailed(String)
        case decodeFailed
    }

    // MARK: - enablement / model location

    /// The llama engine is the DEFAULT inline/translate path. Escape hatches:
    /// `defaults write eu.illegible.prosper inlineEngineLlama -bool false`
    /// (back to the retained MLX inline path) or env
    /// `PROSPER_INLINE_ENGINE=llama|mlx` (bench/CI override).
    static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["PROSPER_INLINE_ENGINE"] {
            return env == "llama"
        }
        if UserDefaults.standard.object(forKey: "inlineEngineLlama") != nil {
            return UserDefaults.standard.bool(forKey: "inlineEngineLlama")
        }
        return true
    }

    // MARK: - model catalog

    /// A downloadable GGUF for the llama engine. Gemma-4 family only — inline
    /// quality tuning (beam thresholds, turn markers, required-prefix byte
    /// semantics) is validated against this tokenizer; other families would
    /// need their own validation pass before joining the list.
    struct CatalogModel: Identifiable, Sendable, Equatable {
        let id: String
        let label: String
        let detail: String
        let fileName: String
        let downloadURL: URL
        let bytes: Int64
        var sizeLabel: String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    }

    /// Public repos, plain 302 to the CDN — no auth. Sizes pinned for progress
    /// when the CDN omits Content-Length (verified against HF 2026-07-03).
    static let catalog: [CatalogModel] = [
        CatalogModel(
            id: "e2b-q4", label: "Gemma 4 E2B (QAT 4-bit)", detail: "fastest, lightest",
            fileName: "gemma-4-E2B_q4_0-it.gguf",
            downloadURL: URL(string: "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf")!,
            bytes: 3_349_514_112),
        CatalogModel(
            id: "e2b-q8", label: "Gemma 4 E2B (8-bit)", detail: "sharper E2B, more RAM",
            fileName: "gemma-4-E2B-it-Q8_0.gguf",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q8_0.gguf")!,
            bytes: 4_967_494_592),
        CatalogModel(
            id: "e4b-q4", label: "Gemma 4 E4B (QAT 4-bit)", detail: "larger base, smarter",
            fileName: "gemma-4-E4B_q4_0-it.gguf",
            downloadURL: URL(string: "https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf/resolve/main/gemma-4-E4B_q4_0-it.gguf")!,
            bytes: 5_154_939_136),
        CatalogModel(
            id: "e4b-q8", label: "Gemma 4 E4B (8-bit)", detail: "smartest, most RAM",
            fileName: "gemma-4-E4B-it-Q8_0.gguf",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q8_0.gguf")!,
            bytes: 8_031_240_160),
    ]

    /// Active catalog entry for inline + translate. Switching unloads the
    /// engine; the next request lazily loads the new file.
    static var selectedModelId: String {
        UserDefaults.standard.string(forKey: "llamaInlineModel") ?? catalog[0].id
    }
    static var selectedModel: CatalogModel {
        catalog.first { $0.id == selectedModelId } ?? catalog[0]
    }
    static func selectModel(_ id: String) {
        guard catalog.contains(where: { $0.id == id }), id != selectedModelId else { return }
        UserDefaults.standard.set(id, forKey: "llamaInlineModel")
        Task { await shared.unload() }
    }

    static func fileURL(for model: CatalogModel) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Prosper/models/gguf/\(model.fileName)")
    }
    static func isDownloaded(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: model).path)
    }

    /// GGUF path: env override (bench) or the selected catalog model.
    static var modelFileURL: URL {
        if let p = ProcessInfo.processInfo.environment["PROSPER_LLAMA_GGUF"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return fileURL(for: selectedModel)
    }

    static var modelIsDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFileURL.path)
    }

    /// Download the GGUF into the app-managed models directory. Idempotent
    /// (no-op when present), atomic (URLSession temp file moved into place),
    /// cancellable. ponytail: no resume-on-interrupt — a broken download
    /// restarts; add HTTP Range resume if users on flaky links complain.
    static func downloadModel(
        _ model: CatalogModel = selectedModel,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let dest = fileURL(for: model)
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
                let task = URLSession.shared.downloadTask(with: model.downloadURL) { tmp, resp, err in
                    if let err { cont.resume(throwing: err); return }
                    guard let tmp,
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
                    else {
                        cont.resume(throwing: EngineError.loadFailed("model download failed"))
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
                            ? task.countOfBytesExpectedToReceive : model.bytes
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

    /// Remove a GGUF from disk (Settings "Delete"). Unloads first so the
    /// mmap isn't yanked out from under a live context.
    static func deleteModel(_ model: CatalogModel = selectedModel) async {
        await shared.unload()
        try? FileManager.default.removeItem(at: fileURL(for: model))
    }

    /// Bench/live tuning knobs without a rebuild (regress sweeps the gate and
    /// width): PROSPER_LLAMA_WIDTH / PROSPER_LLAMA_GATE / PROSPER_LLAMA_MAXNEW.
    static func tunedParams() -> Params {
        var p = Params()
        let env = ProcessInfo.processInfo.environment
        if let v = env["PROSPER_LLAMA_WIDTH"].flatMap({ Int32($0) }) { p.searchWidth = v }
        if let v = env["PROSPER_LLAMA_GATE"].flatMap({ Float($0) }) { p.minAvgLogprob = v }
        if let v = env["PROSPER_LLAMA_MAXNEW"].flatMap({ Int($0) }) { p.maxNewTokens = v }
        if let v = env["PROSPER_LLAMA_FORCE"].flatMap({ Int($0) }) { p.minForcedTokens = v }
        return p
    }

    /// Split a prefill at its last word boundary: the partial word being typed
    /// becomes the byte-level `requiredPrefix` (the reference app mechanism). Feeding a
    /// TRUNCATED word to the tokenizer is out-of-distribution ("disc" is not a
    /// token prefix of "discuss" — regress: mid-word cases decoded junk like
    /// "u..."); constraining decode to the typed bytes instead lets the model
    /// complete the word it actually predicts. Bonus: the prompt stays
    /// byte-identical while a word is being typed, so the KV prefix is fully
    /// reused between keystrokes.
    static func splitRequiredPrefix(_ prefill: String) -> (prefill: String, required: String) {
        guard !prefill.isEmpty else { return ("", "") }
        // Start of the trailing partial word (== endIndex when the text ends
        // in whitespace).
        var cut = prefill.endIndex
        while cut > prefill.startIndex {
            let p = prefill.index(before: cut)
            if prefill[p].isWhitespace { break }
            cut = p
        }
        // Pull ONE preceding space into the required bytes: SentencePiece
        // continuation tokens carry their leading space ("▁disc" == " disc"),
        // so required "disc" after a space-terminated prefill would byte-
        // mismatch every admissible token. Newlines stay in the prefill —
        // post-newline tokens have no leading space, and the decoder both
        // bans and terminates on newline bytes.
        if cut > prefill.startIndex, prefill[prefill.index(before: cut)] == " " {
            cut = prefill.index(before: cut)
        }
        return (String(prefill[..<cut]), String(prefill[cut...]))
    }

    // MARK: - state

    /// Nonisolated "is the GGUF resident" snapshot for UI badges (AI Models
    /// pane) — written on the actor at load/unload, read from the main
    /// thread; a stale badge for one poll tick is harmless.
    nonisolated(unsafe) private(set) static var isLoadedSnapshot = false
    /// Weight bytes of the resident GGUF (0 when unloaded) — the MLX allocator
    /// can't see llama.cpp memory, so the AI Models pane reads this instead.
    nonisolated(unsafe) private(set) static var residentBytesSnapshot: Int64 = 0

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var nVocab = 0
    private var width: Int32 = 0
    private var batch: llama_batch?
    /// Tokens currently materialized in seq 0's KV (prompt prefix reuse).
    private var cachedPromptTokens: [llama_token] = []
    /// Per-token detokenized bytes, filled lazily (beam detoks constantly).
    private var pieceBytes: [llama_token: [UInt8]] = [:]
    /// Scratch for `topCandidates` (vocab-sized, reused across steps — the
    /// softmax + top-k run per beam per step and must stay vectorized: the
    /// scalar loop over a 262k vocab dominated the whole beam at ~1.5s/case).
    private var scratch: [Float] = []

    // MARK: - lifecycle

    func ensureLoaded(params: Params = Params()) throws {
        if ctx != nil { return }
        let path = Self.modelFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.modelMissing(path)
        }
        llama_backend_init()
        llama_log_set({ level, text, _ in
            if level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text {
                NSLog("llama: %@", String(cString: text))
            }
        }, nil)
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(path, mparams) else {
            throw EngineError.loadFailed("model load failed: \(path)")
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_batch = 2048
        cparams.n_ubatch = 512
        cparams.n_seq_max = UInt32(params.searchWidth)
        // Unified KV: seq_cp forks share cells instead of copying them.
        cparams.kv_unified = true
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw EngineError.loadFailed("context init failed")
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        nVocab = Int(llama_vocab_n_tokens(vocab))
        width = params.searchWidth
        batch = llama_batch_init(2048, 0, params.searchWidth)
        cachedPromptTokens = []
        pieceBytes = [:]; piecesFlat = []
        Self.isLoadedSnapshot = true
        Self.residentBytesSnapshot = Int64(llama_model_size(m))
        TraceLog.emit("llama: model loaded (\(path))")
    }

    func unload() {
        Self.isLoadedSnapshot = false
        Self.residentBytesSnapshot = 0
        if let batch { llama_batch_free(batch) }
        batch = nil
        if let ctx { llama_free(ctx) }
        ctx = nil
        if let model { llama_model_free(model) }
        model = nil
        vocab = nil
        cachedPromptTokens = []
        pieceBytes = [:]; piecesFlat = []
    }

    var isLoaded: Bool { ctx != nil }

    // MARK: - tokenize / detokenize

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

    private func bytes(for token: llama_token) -> [UInt8] {
        if let b = pieceBytes[token] { return b }
        var buf = [CChar](repeating: 0, count: 64)
        var t = token
        let n = withUnsafePointer(to: &t) { tp in
            llama_detokenize(vocab, tp, 1, &buf, Int32(buf.count), false, false)
        }
        let b = n >= 0 ? buf.prefix(Int(n)).map { UInt8(bitPattern: $0) } : []
        pieceBytes[token] = b
        return b
    }

    /// Flat piece table for full-vocab byte scans (required-prefix
    /// admissibility). Built once lazily; ~262k small arrays, a few MB.
    private var piecesFlat: [[UInt8]] = []
    private func allPieces() -> [[UInt8]] {
        if piecesFlat.count != nVocab {
            piecesFlat = (0..<nVocab).map { bytes(for: llama_token($0)) }
        }
        return piecesFlat
    }

    private func detok(_ tokens: [llama_token]) -> [UInt8] {
        var out: [UInt8] = []
        for t in tokens { out += bytes(for: t) }
        return out
    }

    // MARK: - completion

    /// One completion request. `system`+`user` render into the user turn of the
    /// Gemma template (Gemma has no system role — same merge the MLX chat
    /// template performs); `prefill` seeds the model turn. `requiredPrefix`
    /// (Phase D) constrains the first decoded bytes; it is STRIPPED from the
    /// returned candidates, which therefore always continue
    /// `prefill + requiredPrefix`.
    func complete(
        system: String,
        user: String,
        prefill: String,
        requiredPrefix: String = "",
        params: Params = Params()
    ) throws -> [Candidate] {
        try ensureLoaded(params: params)
        guard let ctx, var batch else { throw EngineError.loadFailed("no context") }
        let mem = llama_get_memory(ctx)

        // Gemma chat template, hand-rendered: BOS via addSpecial on the head,
        // control tokens parsed, and the prefill appended RAW (no specials —
        // user text must never smuggle a control token).
        var promptTokens = tokenize(templatedHead(system: system, user: user),
                                    addSpecial: true, parseSpecial: true)
        promptTokens += tokenize(prefill, addSpecial: false, parseSpecial: false)

        func batchClear() { batch.n_tokens = 0 }
        func batchAdd(_ token: llama_token, pos: Int32, seq: llama_seq_id, logits: Bool) {
            let i = Int(batch.n_tokens)
            batch.token[i] = token
            batch.pos[i] = pos
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = seq
            batch.logits[i] = logits ? 1 : 0
            batch.n_tokens += 1
        }

        try prefillPrompt(promptTokens, batch: &batch)
        let promptLen = promptTokens.count

        // ---- threshold beam
        struct Beam {
            var seq: llama_seq_id
            var tokens: [llama_token] = []
            var logprobSum: Double = 0
            var done = false
            var logitsRow: Int32 = -1
            /// Bytes of `requiredPrefix` this beam has produced so far.
            var prefixConsumed = 0
            var avg: Double { tokens.isEmpty ? -100 : logprobSum / Double(tokens.count) }
        }

        let required = Array(requiredPrefix.utf8)
        let eos = llama_vocab_eos(vocab)
        let eot = llama_vocab_eot(vocab)
        let newline: UInt8 = 0x0A

        var beams = [Beam(seq: 0, logitsRow: Int32(batch.n_tokens - 1))]
        var freeSeqs: [llama_seq_id] = (1..<width).map { llama_seq_id($0) }

        // Phase D byte constraint: while a beam still owes required-prefix
        // bytes, a token is admissible only if its bytes and the remaining
        // required bytes agree on their overlap (either may be the shorter).
        func admissible(_ beam: Beam, token: llama_token, isEnd: Bool) -> (ok: Bool, consumed: Int) {
            let remaining = required.count - beam.prefixConsumed
            guard remaining > 0 else { return (true, 0) }
            if isEnd { return (false, 0) }  // can't stop before covering the prefix
            let tb = bytes(for: token)
            if tb.isEmpty { return (false, 0) }
            let overlap = min(tb.count, remaining)
            for i in 0..<overlap where tb[i] != required[beam.prefixConsumed + i] {
                return (false, 0)
            }
            return (true, overlap)
        }

        // Admissible token set per consumed-offset, from a full-vocab byte
        // scan (cached — beams at the same offset share it). Without this,
        // top-k over the UNCONSTRAINED vocab often contains no token starting
        // with the required bytes and the beam dead-ends (regress: 32 empties,
        // all mid-word cases).
        var admissibleCache: [Int: [llama_token]] = [:]
        func admissibleTokens(consumed: Int) -> [llama_token] {
            if let hit = admissibleCache[consumed] { return hit }
            let pieces = allPieces()
            var toks: [llama_token] = []
            for t in 0..<pieces.count {
                let tb = pieces[t]
                if tb.isEmpty { continue }
                let overlap = min(tb.count, required.count - consumed)
                var ok = true
                for i in 0..<overlap where tb[i] != required[consumed + i] { ok = false; break }
                if ok { toks.append(llama_token(t)) }
            }
            admissibleCache[consumed] = toks
            return toks
        }

        for step in 0..<params.maxNewTokens {
            if Task.isCancelled { throw CancellationError() }
            var next: [Beam] = []
            // Forced-continuation window: ending tokens (EOT/EOS and anything
            // that emits a newline — Gemma has a whole newline-RUN piece
            // family) are inadmissible for the first `minForcedTokens` steps.
            let forced = step < params.minForcedTokens

            for beam in beams where !beam.done {
                guard let logits = llama_get_logits_ith(ctx, beam.logitsRow) else { continue }
                let cands = beam.prefixConsumed < required.count
                    ? topAdmissible(logits, k: 8, among: admissibleTokens(consumed: beam.prefixConsumed))
                    : topCandidates(logits, k: 8)
                guard let pMax = cands.first?.p else { continue }
                var extended = false
                for c in cands {
                    var isEnd = c.token == eos || c.token == eot
                    if forced, isEnd || bytes(for: c.token).contains(newline) { continue }
                    if forced { isEnd = false }
                    let adm = admissible(beam, token: c.token, isEnd: isEnd)
                    if !extended {
                        // Best admissible token extends the beam in place.
                        guard adm.ok else { continue }
                        var b = beam
                        if isEnd {
                            b.done = true
                        } else {
                            b.tokens.append(c.token)
                            b.logprobSum += Double(c.logprob)
                            b.prefixConsumed += adm.consumed
                        }
                        next.append(b)
                        extended = true
                        continue
                    }
                    // Branch thresholds (the reference app): absolute AND relative.
                    guard adm.ok, !isEnd,
                          c.p >= params.minBranchProbability,
                          c.p >= pMax * params.relativeCutoff,
                          let child = freeSeqs.popLast() else { continue }
                    llama_memory_seq_cp(mem, beam.seq, child, 0, -1)
                    var b = beam
                    b.seq = child
                    b.tokens.append(c.token)
                    b.logprobSum += Double(c.logprob)
                    b.prefixConsumed += adm.consumed
                    next.append(b)
                }
                if !extended {
                    // No admissible continuation (required prefix dead-ends
                    // in this beam): drop it, recycle its sequence.
                    if beam.seq != 0 {
                        llama_memory_seq_rm(mem, beam.seq, -1, -1)
                        freeSeqs.append(beam.seq)
                    }
                }
            }
            next.append(contentsOf: beams.filter { $0.done })

            // Prune to width by avg logprob.
            if next.count > Int(width) {
                next.sort { $0.avg > $1.avg }
                for dead in next[Int(width)...] where !dead.done && dead.seq != 0 {
                    llama_memory_seq_rm(mem, dead.seq, -1, -1)
                    freeSeqs.append(dead.seq)
                }
                next = Array(next.prefix(Int(width)))
            }
            beams = next

            // Newline = end of a one-line suggestion.
            for i in beams.indices where !beams[i].done {
                if detok(beams[i].tokens).contains(newline) { beams[i].done = true }
            }
            if !beams.contains(where: { !$0.done }) { break }

            // ONE decode pass advances every live beam.
            batchClear()
            var row: Int32 = 0
            for (i, beam) in beams.enumerated() where !beam.done {
                guard let last = beam.tokens.last else { continue }
                batchAdd(last, pos: Int32(promptLen + beam.tokens.count - 1),
                         seq: beam.seq, logits: true)
                beams[i].logitsRow = row
                row += 1
            }
            if batch.n_tokens == 0 { break }
            guard llama_decode(ctx, batch) == 0 else { throw EngineError.decodeFailed }
        }

        // Beam scratch is garbage for the NEXT request's prefix reuse: only
        // seq 0's prompt prefix is kept (the beam grew seq 0 past promptLen —
        // trim it back so the cache invariant holds).
        llama_memory_seq_rm(mem, 0, llama_pos(promptLen), -1)
        for s in 1..<width { llama_memory_seq_rm(mem, llama_seq_id(s), -1, -1) }

        // ---- rank, strip required prefix, gate
        var out: [Candidate] = []
        for b in beams.sorted(by: { $0.avg > $1.avg }) {
            guard !b.tokens.isEmpty, b.prefixConsumed >= required.count else { continue }
            guard b.avg >= Double(params.minAvgLogprob) else { continue }
            var raw = detok(b.tokens)
            if let nl = raw.firstIndex(of: newline) { raw = Array(raw[..<nl]) }
            guard raw.count > required.count else { continue }
            let text = String(decoding: raw.dropFirst(required.count), as: UTF8.self)
            if !text.isEmpty { out.append(Candidate(text: text, avgLogprob: Float(b.avg))) }
        }
        return out
    }

    // MARK: - shared prompt machinery

    /// Gemma chat template head (user turn + opened model turn).
    private func templatedHead(system: String, user: String) -> String {
        "<start_of_turn>user\n"
            + (system.isEmpty ? "" : system + "\n\n")
            + user
            + "<end_of_turn>\n<start_of_turn>model\n"
    }

    /// Decode `promptTokens` into seq 0 with KV prefix reuse (reference
    /// prefix-reuse): drop only the suffix that changed since the last
    /// request, re-decode the rest. The frozen inline context keeps prompts
    /// byte-stable across keystrokes, so the common case re-decodes just the
    /// few new tail tokens. Leaves `batch` holding the decoded tail with
    /// logits requested on the LAST row.
    private func prefillPrompt(_ promptTokens: [llama_token], batch: inout llama_batch) throws {
        guard let ctx else { throw EngineError.loadFailed("no context") }
        let mem = llama_get_memory(ctx)
        var lcp = 0
        while lcp < min(cachedPromptTokens.count, promptTokens.count),
              cachedPromptTokens[lcp] == promptTokens[lcp] { lcp += 1 }
        // Always leave at least one token to decode: root logits come from
        // the LAST prompt token's row of this decode pass.
        if lcp == promptTokens.count { lcp -= 1 }
        if lcp < cachedPromptTokens.count {
            llama_memory_seq_rm(mem, 0, llama_pos(lcp), -1)
        }
        // Scratch sequences from the previous request.
        for s in 1..<width { llama_memory_seq_rm(mem, llama_seq_id(s), -1, -1) }

        batch.n_tokens = 0
        for i in lcp..<promptTokens.count {
            let row = Int(batch.n_tokens)
            batch.token[row] = promptTokens[i]
            batch.pos[row] = Int32(i)
            batch.n_seq_id[row] = 1
            batch.seq_id[row]![0] = 0
            batch.logits[row] = (i == promptTokens.count - 1) ? 1 : 0
            batch.n_tokens += 1
        }
        guard llama_decode(ctx, batch) == 0 else {
            cachedPromptTokens = []
            llama_memory_seq_rm(mem, 0, -1, -1)
            throw EngineError.decodeFailed
        }
        cachedPromptTokens = promptTokens
    }

    // MARK: - greedy chat generation (Translate)

    /// Banned-token sets per banned-characters string (script constraint) —
    /// a full-vocab byte scan, cached because the alphabet per target
    /// language is a handful of fixed strings.
    private var bannedTokenCache: [String: [llama_token]] = [:]
    private func bannedTokens(for characters: String) -> [llama_token] {
        if characters.isEmpty { return [] }
        if let hit = bannedTokenCache[characters] { return hit }
        let needles = characters.map { Array(String($0).utf8) }
        let pieces = allPieces()
        var toks: [llama_token] = []
        for t in 0..<pieces.count {
            let tb = pieces[t]
            guard tb.count > 0 else { continue }
            var banned = false
            for needle in needles where tb.count >= needle.count {
                for start in 0...(tb.count - needle.count) {
                    var match = true
                    for i in 0..<needle.count where tb[start + i] != needle[i] { match = false; break }
                    if match { banned = true; break }
                }
                if banned { break }
            }
            if banned { toks.append(llama_token(t)) }
        }
        bannedTokenCache[characters] = toks
        return toks
    }

    /// Single-sequence greedy chat generation on the SAME loaded GGUF — this
    /// serves the Translate extension, so translate no longer needs the MLX
    /// inline model resident at all (one runtime, one copy of the weights).
    ///
    /// `bannedCharacters` is a decode-time script constraint: any token whose
    /// bytes contain one of these characters gets -inf logits, so a
    /// sister-language letter (ы э ё for a Bulgarian target, …) can never be
    /// SAMPLED — strictly stronger than detecting the leak afterwards and
    /// asking the model to proofread its own output.
    /// Gemma-4 chat head with the vocab's REAL turn tokens (`<|turn>`,
    /// `<turn|>` — from the GGUF's tokenizer.chat_template) and a real system
    /// turn. The inline path keeps its own `templatedHead` on purpose: its
    /// decode behavior and regress baseline were tuned against that exact
    /// prompt, and raw continuation doesn't need chat framing.
    private func chatHead(system: String, user: String) -> String {
        (system.isEmpty ? "" : "<|turn>system\n" + system + "<turn|>\n")
            + "<|turn>user\n" + user + "<turn|>\n<|turn>model\n"
    }

    /// `partialEvery` > 0 with `onPartial` set emits the growing decoded text
    /// every N tokens (whole-array detok — correct across multibyte boundaries;
    /// N coalesces the O(n²) cost). Used by the QuickChat staged job to stream
    /// tokens into the runner. Default off — existing callers are unaffected.
    func generate(
        system: String,
        user: String,
        maxTokens: Int,
        bannedCharacters: String = "",
        partialEvery: Int = 0,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
        try ensureLoaded(params: Self.tunedParams())
        guard let ctx, var batch else { throw EngineError.loadFailed("no context") }
        let mem = llama_get_memory(ctx)

        let promptTokens = tokenize(chatHead(system: system, user: user),
                                    addSpecial: true, parseSpecial: true)
        try prefillPrompt(promptTokens, batch: &batch)
        let promptLen = promptTokens.count

        let banned = bannedTokens(for: bannedCharacters)
        let eos = llama_vocab_eos(vocab)
        let eot = llama_vocab_eot(vocab)
        // This vocab reports eot = -1; the actual end-of-turn is `<turn|>`.
        let turnEnd = tokenize("<turn|>", addSpecial: false, parseSpecial: true).first ?? -1

        var out: [llama_token] = []
        var logitsRow = Int32(batch.n_tokens - 1)
        for _ in 0..<maxTokens {
            if Task.isCancelled { throw CancellationError() }
            guard let logits = llama_get_logits_ith(ctx, logitsRow) else { break }
            for t in banned { logits[Int(t)] = -.greatestFiniteMagnitude }
            var v: Float = 0
            var idx: vDSP_Length = 0
            vDSP_maxvi(logits, 1, &v, &idx, vDSP_Length(nVocab))
            let tok = llama_token(idx)
            if tok == eos || tok == eot || tok == turnEnd || llama_vocab_is_eog(vocab, tok) { break }
            out.append(tok)
            batch.n_tokens = 0
            batch.token[0] = tok
            batch.pos[0] = Int32(promptLen + out.count - 1)
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            batch.n_tokens = 1
            guard llama_decode(ctx, batch) == 0 else { throw EngineError.decodeFailed }
            logitsRow = 0
            if let onPartial, partialEvery > 0, out.count % partialEvery == 0 {
                onPartial(String(decoding: detok(out), as: UTF8.self))
            }
        }

        // Trim seq 0 back to the prompt so the NEXT request's prefix-reuse
        // invariant (cachedPromptTokens == materialized KV) holds.
        llama_memory_seq_rm(mem, 0, llama_pos(promptLen), -1)
        return String(decoding: detok(out), as: UTF8.self)
    }

    // MARK: - logits helpers

    /// Top-k tokens with log-softmax scores (clamped at -100) over one row.
    /// Fully vDSP-vectorized — this runs per beam per step over the whole
    /// vocab, so a scalar loop here is the difference between a ~300ms and a
    /// ~1.5s beam (measured, debug build).
    private func topCandidates(
        _ logits: UnsafeMutablePointer<Float>, k: Int
    ) -> [(token: llama_token, logprob: Float, p: Float)] {
        let n = vDSP_Length(nVocab)
        var maxv: Float = 0
        vDSP_maxv(logits, 1, &maxv, n)
        if scratch.count != nVocab { scratch = [Float](repeating: 0, count: nVocab) }
        // scratch = exp(logits - maxv); sum for the softmax normalizer.
        var sumExp: Float = 0
        var negMax = -maxv
        var count32 = Int32(nVocab)
        scratch.withUnsafeMutableBufferPointer { s in
            vDSP_vsadd(logits, 1, &negMax, s.baseAddress!, 1, n)
            vvexpf(s.baseAddress!, s.baseAddress!, &count32)
            vDSP_sve(s.baseAddress!, 1, &sumExp, n)
        }
        let logZ = logf(sumExp)
        // Top-k by k vectorized argmax passes over the raw logits (k is 8;
        // 8·vDSP_maxvi beats any scalar scan). Found slots are knocked out in
        // scratch — reusing it as the mutable copy — so reload it from logits.
        var best: [(Int, Float)] = []
        scratch.withUnsafeMutableBufferPointer { s in
            cblas_scopy(Int32(nVocab), logits, 1, s.baseAddress!, 1)
            for _ in 0..<k {
                var v: Float = 0
                var idx: vDSP_Length = 0
                vDSP_maxvi(s.baseAddress!, 1, &v, &idx, n)
                best.append((Int(idx), v))
                s[Int(idx)] = -.greatestFiniteMagnitude
            }
        }
        return best.map {
            let lp = ($0.1 - maxv) - logZ
            return (llama_token($0.0), max(lp, -100), expf(lp))
        }
    }

    /// Top-k restricted to `among`, softmax RENORMALIZED over that subset —
    /// The reference app's required-prefix logit processor masks the vocab and lets the
    /// sampler renormalize, so forced prefix tokens don't tank the average
    /// (picking the best of 3 admissible tokens is not a low-confidence event).
    private func topAdmissible(
        _ logits: UnsafeMutablePointer<Float>, k: Int, among: [llama_token]
    ) -> [(token: llama_token, logprob: Float, p: Float)] {
        guard !among.isEmpty else { return [] }
        var vals = [Float](repeating: 0, count: among.count)
        for (i, t) in among.enumerated() { vals[i] = logits[Int(t)] }
        var maxv: Float = 0
        vDSP_maxv(vals, 1, &maxv, vDSP_Length(vals.count))
        var sumExp: Float = 0
        var negMax = -maxv
        var count32 = Int32(vals.count)
        var expd = [Float](repeating: 0, count: vals.count)
        vDSP_vsadd(vals, 1, &negMax, &expd, 1, vDSP_Length(vals.count))
        vvexpf(&expd, expd, &count32)
        vDSP_sve(expd, 1, &sumExp, vDSP_Length(vals.count))
        let logZ = logf(sumExp)
        let order = vals.indices.sorted { vals[$0] > vals[$1] }.prefix(k)
        return order.map {
            let lp = (vals[$0] - maxv) - logZ
            return (among[$0], max(lp, -100), expf(lp))
        }
    }
}
