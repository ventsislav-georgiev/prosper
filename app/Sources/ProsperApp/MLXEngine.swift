import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import os
import Tokenizers

// In-process inference engine backed by Apple's MLX (mlx-swift + mlx-swift-lm).
//
// This replaces the Rust/Ollama core for inference.
//
// Default model: `mlx-community/gemma-4-e2b-it-6bit` (Gemma 4 E2B, uniform 6-bit).
//
// GEMMA 4 NOTE: Gemma 4 is a multimodal family, but mlx-swift-lm registers the
// E2B/E4B checkpoints in `LLMModelFactory`'s `LLMRegistry` and ships the
// `gemma4` / `gemma4_text` architectures (Gemma4.swift / Gemma4Text.swift). The
// text-only path used here runs them directly — no VLM/vision tower required.
// `mlx-community/gemma-4-e4b-it-6bit` is the larger E4B sibling, selectable via
// Preferences. (The old `mlx-swift-examples` dependency had no gemma4 arch.)

/// Errors surfaced by `MLXEngine`.
enum MLXEngineError: LocalizedError {
    case notLoaded
    case emptyOutput
    case mlxRuntime(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The language model is not loaded yet."
        case .emptyOutput:
            return "The model produced no output."
        case .mlxRuntime(let message):
            return "MLX runtime error: \(message)"
        }
    }
}

/// Thread-safe capture of the first MLX runtime error message raised inside a
/// guarded scope (see `withMLXErrorGuard`).
final class MLXErrorCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    func record(_ message: String) {
        lock.withLock { if first == nil { first = message } }
    }
    var message: String? { lock.withLock { first } }
}

/// Run `body` with a scoped MLX error handler so C++-level MLX errors (shape
/// mismatches inside scaled_dot_product_attention, impossible reshapes, …)
/// surface as a thrown `MLXEngineError.mlxRuntime` instead of the library
/// default, which is `fatalError` — a hard app crash. (Seen in the field:
/// EXC_BREAKPOINT in `ErrorHandler.dispatch` ← `_mlx_error` ←
/// `mlx_fast_scaled_dot_product_attention` during inline decode.)
///
/// The handler rides a Swift `@TaskLocal` (mlx-swift `ErrorHandler`), and
/// `MLXLMCommon.generate`'s internal loop runs in a `Task {}` created inside
/// this scope, so the loop task inherits the guard for its entire lifetime —
/// including any error raised after `body` returns. `body` receives the
/// capture so streaming loops can break out as soon as an error lands instead
/// of decoding garbage to the token cap.
private func withMLXErrorGuard<R>(
    _ label: String, _ body: (MLXErrorCapture) async throws -> R
) async throws -> R {
    let capture = MLXErrorCapture()
    let result = try await MLX.withErrorHandler(
        { message in
            capture.record(message)
            NSLog("prosper mlx: runtime error in %@: %@", label, message)
        },
        { try await body(capture) })
    if let message = capture.message {
        throw MLXEngineError.mlxRuntime("\(label): \(message)")
    }
    return result
}

/// Thread-safe holder for the live download `Progress`. The Hugging Face Hub
/// downloader invokes its progress *handler* only ONCE — at download start,
/// before any bytes arrive (see swift-huggingface `downloadSnapshot`, which calls
/// `progressHandler(progress)` a single time then never again). It keeps updating
/// that SAME `NSProgress` instance throughout the download via its URLSession
/// delegate. So a handler-only consumer freezes on the first sample (e.g.
/// "32 MB of 3.6 GB"). We capture the instance here and poll it, so the UI tracks
/// the live `fractionCompleted` in real time. `NSProgress` reads are thread-safe.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Progress?
    func set(_ p: Progress) { lock.lock(); value = p; lock.unlock() }
    func get() -> Progress? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Actor wrapping a single MLX `ModelContainer`. Loads the model once (lazily)
/// and serves single-shot text generations. Structured so streaming can be added
/// later by yielding `.chunk` values instead of accumulating them.
actor MLXEngine {

    /// Shared engine instance used by `CoreBridge`.
    static let shared = MLXEngine()

    /// Nonisolated "is the shared inline model resident" snapshot, readable from the
    /// SwiftUI AI Models pane without an actor hop. Flipped only by the SHARED engine's
    /// `load`/`unload` (the agent runs on a separate instance — see
    /// `ModelResidencyCoordinator.isAgentActive` for that one).
    private static let inlineLoadedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    nonisolated static var isInlineModelLoaded: Bool { inlineLoadedFlag.withLock { $0 } }

    /// Currently-resident MLX memory in bytes (active arrays — weights + live KV). Only
    /// one LLM is resident at a time (inline OR agent — `ModelResidencyCoordinator`), so
    /// this is effectively the loaded model's footprint. Nonisolated: a plain global read.
    nonisolated static var residentMemoryBytes: Int64 { Int64(MLX.GPU.activeMemory) }

    /// Hugging Face model id (MLX format). Configurable via Preferences and swappable
    /// at runtime via `prepareSwitch(to:)` (the Settings model picker → live switch).
    private(set) var modelId: String

    /// Loaded text container, or nil until `load` completes.
    private var container: ModelContainer?

    /// In-flight generation count (inline + `generate` + chat). Unload paths consult it so a
    /// free can't `clearCache()` GPU buffers under an active compute. Actor-isolated →
    /// no lock; stays >0 across a generation's internal `await`s (where actor reentrancy
    /// would otherwise let an unload run), so a concurrent unload correctly defers.
    private var activeGenerations = 0

    /// A forced unload (`requestUnload`) that arrived mid-generation, to run when the
    /// last generation finishes. Lets autocomplete-disable / load-cancel free memory
    /// without freeing buffers under an active compute.
    private var pendingUnload = false

    /// Decrement the in-flight count and, when it reaches zero, run any unload that was
    /// deferred because it arrived mid-generation. Called from every generation's `defer`.
    private func endGeneration() {
        activeGenerations -= 1
        if activeGenerations == 0 && pendingUnload { unload() }
    }

    /// Persistent KV cache for the inline-completion path, reused across
    /// keystrokes. `KVCache` is a non-Sendable reference type and `ModelContainer
    /// .perform` takes a `@Sendable` closure, so the cache lives in this box that
    /// the closure captures. The box is `@unchecked Sendable` because the
    /// `MLXEngine` actor serializes every access — no two generations touch it
    /// concurrently. `tokens` mirrors the prompt tokens currently primed into the
    /// cache so the next request can reuse the longest common prefix.
    private final class InlineCacheBox: @unchecked Sendable {
        var caches: [KVCache]?
        var tokens: [Int] = []
        func reset() { caches = nil; tokens = [] }
    }
    private let inlineBox = InlineCacheBox()

    /// Persistent KV cache for the agent chat path (`streamChat`), reused across
    /// requests. Agent conversations grow append-only — each codex round trip
    /// re-sends the whole prior conversation plus a new tail — so consecutive
    /// requests share a huge token prefix. Without reuse every round trip
    /// re-prefills the entire (10k+ token) history; with it, prefill is just the
    /// new tail. Unlike `inlineBox`, the *generated* tokens are kept in the cache
    /// too (the next request's prompt contains this response verbatim).
    private let chatBox = InlineCacheBox()

    /// Guards against concurrent loads; once loaded, subsequent calls are no-ops.
    private var loadTask: Task<ModelContainer, Error>?

    /// Loaded vision (VLM) container, loaded lazily only when the screenshot /
    /// vision-context feature is used. Same checkpoint id, loaded through
    /// `VLMModelFactory` so the multimodal (gemma4) path with the vision tower is
    /// available. Kept separate so text-only users never pay the VLM memory cost.
    private var vlmContainer: ModelContainer?
    private var vlmLoadTask: Task<ModelContainer, Error>?

    /// Lazily-loaded **draft** container for speculative decoding (WS2). Loaded only
    /// when `Preferences.speculativeDecodingEnabled` via `loadDraft()`, through the
    /// SAME `LLMModelFactory` + downloader path as the main `container`, just a smaller
    /// model id (`Preferences.draftModelId`). Kept separate so non-speculative users
    /// never pay its memory cost.
    ///
    /// TOKENIZER-MATCH REQUIREMENT (critical): the draft model MUST share the main
    /// model's tokenizer or `SpeculativeTokenIterator` throws / mis-decodes at run
    /// time (the verifier maps the draft's token ids onto its own logits). We do not —
    /// and cannot cheaply — validate this at load time; a wrong `draftModelId` surfaces
    /// only when speculative decode runs, at which point `generateInlineSpeculative`
    /// falls back to the single-model path. See `Preferences.defaultDraftModelId`.
    ///
    /// MEMORY: this is a SECOND resident model. Its weights live in *active* memory
    /// (the 384 MB `configureMemoryLimits()` cap only bounds the transient GPU buffer
    /// pool, not weights), so enabling speculative decoding materially raises RSS.
    private let draftModelId: String
    private var draftContainer: ModelContainer?
    private var draftLoadTask: Task<ModelContainer, Error>?

    init(modelId: String = Preferences.coreModel,
         draftModelId: String = Preferences.draftModelId) {
        self.modelId = modelId
        self.draftModelId = draftModelId
    }

    /// True once the model is loaded and ready to generate.
    var isLoaded: Bool { container != nil }

    /// Human-readable byte count (e.g. "450.2 MB", "3.6 GB"). `nonisolated` so the
    /// @Sendable download-progress closure can call it without actor hops.
    nonisolated static func fmtBytes(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        if b >= 1_000_000_000 { return String(format: "%.1f GB", b / 1_000_000_000) }
        if b >= 1_000_000 { return String(format: "%.0f MB", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB", b / 1_000) }
        return "\(Int(b)) B"
    }

    /// Polls real downloaded bytes ~3×/sec and forwards (fraction, status) so the
    /// UI advances in real time. Cancel when the load finishes.
    ///
    /// Why we poll the disk instead of the Hub `Progress`: swift-huggingface drives
    /// its download with `URLSession.download(for:delegate:)`, but on macOS the
    /// per-task delegate's `urlSession(_:downloadTask:didWriteData:…)` callback is
    /// never delivered (a long-standing Foundation bug). So the Hub `Progress` only
    /// moves when a *whole file* finishes — it sits frozen for the entire multi-GB
    /// weight file (e.g. "32 MB of 3.6 GB" for the whole `model.safetensors` pull,
    /// where 32 MB is the already-finished `tokenizer.json`). The only real-time
    /// byte signal is on disk: completed blobs in the HF cache plus the in-flight
    /// `CFNetworkDownload_*.tmp` files URLSession streams into `$TMPDIR`. We use the
    /// Hub `Progress` solely for the reliable *total* (set once, up front).
    nonisolated private static func startProgressPoll(
        _ box: ProgressBox,
        modelId: String,
        fallback: String,
        _ progress: @escaping @Sendable (Double, String) -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            // Track disk-byte growth so we can tell "download finished, now loading
            // into memory" (bytes plateaued) apart from "still downloading" (bytes
            // climbing). The `total` from the Hub Progress only covers the matched
            // weight glob; mlx-swift-lm then runs a SECOND, progress-less download
            // for tokenizer files (e.g. Gemma's `tokenizer.model`, not caught by the
            // `*.safetensors/*.json/*.jinja` glob). During that phase `done >= total`
            // yet the network is still active — so reaching `total` alone must NOT be
            // read as "loading into memory", or we mislabel an in-flight download.
            var lastRaw: Int64 = -1
            var stalls = 0
            // ~6 polls × 350 ms ≈ 2 s of zero growth before we declare the byte
            // phase done and the remaining wait an in-memory load.
            let stallThreshold = 6
            // Only count URLSession temp files written by THIS load. A 5 s slack
            // absorbs clock/creation skew on the live file while still excluding
            // stale temps left by earlier aborted attempts.
            let started = Date().addingTimeInterval(-5)
            while !Task.isCancelled {
                if let p = box.get() {
                    let total = p.totalUnitCount
                    if total > 1_000_000 {
                        let raw = diskDownloadedBytes(modelId: modelId, since: started)
                        if raw > lastRaw { stalls = 0 } else { stalls += 1 }
                        lastRaw = raw
                        let done = min(raw, total)
                        let frac = Double(done) / Double(total)

                        if done >= total && stalls >= stallThreshold {
                            // Bytes stopped growing at/after the weight total: the
                            // download (incl. the trailing tokenizer fetch) is done
                            // and the remaining wait is MLX mapping weights into
                            // memory — no byte signal, slow on a cold first load.
                            progress(1.0, "Loading model into memory\u{2026}")
                        } else if done >= total {
                            // Hit the weight total but bytes are still arriving —
                            // the tokenizer / extra files are downloading. Honest:
                            // the network is still in use.
                            progress(1.0, "Finishing download\u{2026}")
                        } else {
                            progress(frac, "Downloading model — \(fmtBytes(done)) of \(fmtBytes(total))")
                        }
                    } else {
                        progress(p.fractionCompleted, p.localizedDescription ?? fallback)
                    }
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    /// Best-effort count of bytes already on disk for `modelId`: committed blobs in
    /// the HF cache plus any in-flight `CFNetworkDownload_*.tmp` files URLSession is
    /// streaming into the process temp dir. The big weight file lives only in the
    /// URLSession temp until it finishes, then is moved into `blobs/`, so a file is
    /// counted in exactly one place at a time (the caller still clamps to `total`).
    nonisolated private static func diskDownloadedBytes(modelId: String, since: Date) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        func sumFiles(in dir: URL, keys: [URLResourceKey] = [.fileSizeKey],
                      where include: (URL) -> Bool = { _ in true }) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: []
            ) else { return }
            for url in items where include(url) {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        // Committed (and resumable .incomplete) blobs for this specific model.
        let dirName = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let blobs = ModelPaths.hubURL
            .appendingPathComponent(dirName).appendingPathComponent("blobs")
        sumFiles(in: blobs)
        // In-flight URLSession download temp files (the multi-GB weight file lands
        // here until complete). Naming has been stable across macOS releases. Count
        // only files modified after this load began — stale CFNetworkDownload temps
        // from earlier aborted attempts would otherwise inflate the total and make
        // us declare the download "finished" while it is still streaming.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        sumFiles(in: tmp, keys: [.fileSizeKey, .contentModificationDateKey]) { url in
            guard url.lastPathComponent.hasPrefix("CFNetworkDownload_") else { return false }
            let mtime = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return mtime >= since
        }
        return total
    }

    /// Resolve + download (if needed) and load the model, forwarding Hub download
    /// progress as (fraction 0..1, status text). Idempotent: only loads once.
    /// Bounds MLX's Metal buffer cache. The model weights live in *active*
    /// memory; the cache pool holds transient scratch buffers freed between ops
    /// and, left unbounded (the MLX default), balloons to many GB after a few
    /// large prefills — buffers MLX keeps for reuse instead of returning to the
    /// OS. Capping it lets MLX release the surplus, so idle RSS stays near the
    /// model's working set rather than climbing without bound. Idempotent.
    nonisolated static func configureMemoryLimits() {
        // 384 MB keeps enough scratch for fast repeated inference while
        // preventing the multi-GB runaway users observed.
        MLX.GPU.set(cacheLimit: 384 * 1024 * 1024)
    }

    func load(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        Self.configureMemoryLimits()
        if container != nil { return }

        // Coalesce concurrent callers onto a single in-flight load.
        if let loadTask {
            _ = try await loadTask.value
            return
        }

        let id = modelId
        // The Hub downloader calls its handler once (at start) and then keeps
        // updating the same NSProgress. Capture it; poll it for live updates.
        let box = ProgressBox()
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(id: id)
            // mlx-swift-lm 3.x requires an explicit Downloader + TokenizerLoader.
            // The MLXHuggingFace macros wire the default HuggingFace Hub client +
            // AutoTokenizer (backed by swift-transformers).
            let downloader = #hubDownloader()
            let loader = #huggingFaceTokenizerLoader()
            return try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: loader,
                configuration: configuration
            ) { p in box.set(p) }
        }
        loadTask = task
        let poll = Self.startProgressPoll(box, modelId: id, fallback: "Downloading model\u{2026}", progress)

        do {
            let loaded = try await task.value
            poll.cancel()
            container = loaded
            if self === Self.shared { Self.inlineLoadedFlag.withLock { $0 = true } }
            inlineBox.reset() // a fresh model invalidates any primed inline cache
            chatBox.reset()
            loadTask = nil
            progress(1.0, "Model ready.")
        } catch {
            poll.cancel()
            loadTask = nil
            throw error
        }
    }

    /// Download a model's files into the on-disk Hub cache **without loading any
    /// weights into memory** — for the Settings "download on select" flow. Reuses the
    /// exact same downloader, glob patterns, and disk-polling progress as `load()`, so
    /// the agent's later lazy load finds the cache already populated. Throws
    /// `CancellationError` when the surrounding task is cancelled (Stop button).
    ///
    /// Download-only (no `loadContainer`) is deliberate: the big agent models are
    /// 18–580 GB and must be fetchable on Macs that can't hold them in RAM.
    nonisolated static func downloadModelFiles(
        modelId: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let box = ProgressBox()
        let task = Task<Void, Error> {
            let downloader = #hubDownloader()
            // Same patterns ModelFactory uses (model weights + tokenizer configs).
            _ = try await downloader.download(
                id: modelId, revision: nil,
                matching: ["*.safetensors", "*.json", "*.jinja"],
                useLatest: false
            ) { p in box.set(p) }
        }
        let poll = startProgressPoll(box, modelId: modelId,
                                     fallback: "Downloading model\u{2026}", progress)
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            poll.cancel()
            progress(1.0, "Downloaded.")
        } catch {
            poll.cancel()
            throw error
        }
    }

    /// True once the draft model is loaded and ready for speculative decoding.
    var isDraftLoaded: Bool { draftContainer != nil }

    /// Load the **draft** container for speculative decoding (WS2). Idempotent and
    /// lazy: only call when `Preferences.speculativeDecodingEnabled`. Mirrors `load()`
    /// exactly — same `LLMModelFactory.shared.loadContainer` + `#hubDownloader()` +
    /// `#huggingFaceTokenizerLoader()` path — only the model id differs
    /// (`draftModelId`). Progress is forwarded the same way so first-time draft
    /// downloads surface in the UI.
    ///
    /// On failure the draft simply stays unloaded; `generateInlineSpeculative` then
    /// falls back to the single-model path, so a missing/broken draft is never worse
    /// than today. See the tokenizer-match + memory notes on `draftContainer`.
    func loadDraft(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        Self.configureMemoryLimits()
        if draftContainer != nil { return }
        if let draftLoadTask {
            _ = try await draftLoadTask.value
            return
        }
        let id = draftModelId
        let box = ProgressBox()
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(id: id)
            let downloader = #hubDownloader()
            let loader = #huggingFaceTokenizerLoader()
            return try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: loader,
                configuration: configuration
            ) { p in box.set(p) }
        }
        draftLoadTask = task
        let poll = Self.startProgressPoll(box, modelId: id, fallback: "Downloading draft model\u{2026}", progress)
        do {
            draftContainer = try await task.value
            poll.cancel()
            draftLoadTask = nil
        } catch {
            poll.cancel()
            draftLoadTask = nil
            throw error
        }
    }

    /// Free ALL resident LLM state and cancel any in-flight loads: the text
    /// container, the vision (VLM) container, the draft (speculative) container, the
    /// primed inline KV cache, and the pooled Metal buffers. Called when the user
    /// disables inline autocomplete — the
    /// model weights are the app's largest memory consumer (multi-GB) and nothing
    /// else should keep them resident. `load()`/`loadVLM()` are lazy and idempotent,
    /// so any on-demand consumer (command runner, extensions) transparently reloads
    /// on next use. Idempotent: safe to call when already unloaded.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        vlmLoadTask?.cancel()
        vlmLoadTask = nil
        draftLoadTask?.cancel()  // WS2: cancel any in-flight draft load
        draftLoadTask = nil
        container = nil
        if self === Self.shared { Self.inlineLoadedFlag.withLock { $0 = false } }
        vlmContainer = nil
        draftContainer = nil     // WS2: drop the second (draft) model's weights
        inlineBox.reset()        // drop primed KV cache so a reload starts clean
        chatBox.reset()
        didWarmup = false        // next load must re-warm the kernels
        pendingUnload = false     // satisfied any deferred forced unload
        MLX.GPU.clearCache()     // release pooled GPU buffers held by the weights
    }

    /// Unload only when no generation is in flight. The idle auto-unloader calls this
    /// (not `unload` directly) so a timer firing during a translation defers instead
    /// of freeing GPU buffers mid-compute. A no-op while busy; the next idle tick
    /// (re-armed on the generation's completion) reclaims the memory.
    func unloadIfIdle() {
        guard activeGenerations == 0 else { return }
        unload()
    }

    /// Cancel a deferred forced unload (a `requestUnload` that set `pendingUnload` while
    /// busy). Called when something decides the model must stay resident — e.g. autocomplete
    /// re-enabled — before the in-flight generation that would drain `pendingUnload` finishes.
    /// Without this, a disable→enable toggle during a generation would free the model out
    /// from under now-enabled autocomplete when that generation completes.
    func cancelPendingUnload() { pendingUnload = false }

    /// Forced unload that must happen but can't free buffers under an active compute.
    /// Frees now if idle; otherwise marks `pendingUnload` so the last in-flight
    /// generation frees on completion (`endGeneration`). Used by autocomplete-disable
    /// and load-cancel. Unlike `unloadIfIdle`, the unload is never dropped — only deferred.
    func requestUnload() {
        guard activeGenerations == 0 else { pendingUnload = true; return }
        unload()
    }

    /// Prepare a live model switch: drop the current container (+ draft / VLM / adapter
    /// / KV cache) and repoint `modelId` at `newId`, so the next `load()` downloads and
    /// loads the newly selected checkpoint instead of early-returning on the old one.
    /// No-op when `newId` already matches the current model. The caller then drives
    /// `load()` (via `CoreBridge.switchModel`) to surface download progress + re-warm.
    func prepareSwitch(to newId: String) {
        guard newId != modelId else { return }
        unload()
        modelId = newId
    }

    /// Single-shot text generation. Builds a chat from the optional `system`
    /// instruction plus the user `prompt`, then collects the full decoded output.
    ///
    /// `repetitionPenalty` (>1 discourages loops/echoes) and `topP` (nucleus
    /// sampling) sharpen completion quality; callers pass tuned values for the
    /// inline-autocomplete path. Defaults keep the translation/generic callers
    /// behaving as before.
    /// Build `GenerateParameters`, applying the repetition penalty only when a
    /// caller supplies one. We deliberately do NOT override `repetitionContextSize`
    /// — a hardcoded value (40) made MLX abort with a `broadcast_shapes` fatal
    /// (`Shapes (40) and (N)`) when the prompt token count differed; the library
    /// default is the tested path. `GenerateParameters` is a value type, so the
    /// optional penalty is set post-init rather than via an unconditional argument.
    /// Hard ceiling on prompt tokens fed to the model. Kept below Gemma 4's
    /// 512-token sliding window (with margin) so prefill stays in one window chunk,
    /// and bounded for speed: the shorter the prompt, the faster the prefill, which
    /// is what makes inline completions feel instant while typing. Applied by
    /// trimming oldest tokens, retaining the most recent context (the user's latest
    /// text + cursor), which matters most for a completion.
    ///
    /// Note: the running sequence (prompt + decoded tokens) routinely exceeds 512 —
    /// e.g. translation decodes 320 on top of this — and the `RotatingKVCache` simply
    /// rotates, which is correct and does NOT crash. The `[reshape]` typing crash was
    /// never about rotation; it was a token-array rank bug in the inline prefill (a
    /// 2-D `[1, N]` token array fed where the library expects 1-D `[N]`). See the
    /// `LMInput(tokens:)` construction in `generateInline`.
    private static let maxPromptTokens = 480

    /// Gate for the inline timing log: on only when `PROSPER_INLINE_TIMING` is set
    /// in the environment, so normal runs stay silent and pay nothing.
    nonisolated static let inlineTimingEnabled =
        ProcessInfo.processInfo.environment["PROSPER_INLINE_TIMING"] != nil

    /// Gate for the agent chat timing log (`streamChat` prefix-cache reuse +
    /// prefill/decode wall clock): on only when `PROSPER_AGENT_TIMING` is set.
    nonisolated static let agentTimingEnabled =
        ProcessInfo.processInfo.environment["PROSPER_AGENT_TIMING"] != nil

    /// Returns the prefix of `text` holding exactly `maxWords` whitespace-delimited
    /// words once a further word has begun (so decode can stop early), preserving
    /// the original trailing whitespace. Returns nil while under the cap, or when
    /// `maxWords <= 0` (cap disabled). Counting the *start* of each word means a
    /// completion that continues the current word (no leading space) still counts
    /// that continuation as its first word.
    static func wordCapped(_ text: String, maxWords: Int) -> String? {
        guard maxWords > 0 else { return nil }
        var count = 0
        var inWord = false
        for idx in text.indices {
            if text[idx].isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
                if count > maxWords { return String(text[..<idx]) }
            }
        }
        return nil
    }

    /// Pure plan for prompt-prefix KV-cache reuse: given the prompt tokens already
    /// primed into the cache (`previous`) and the new prompt (`current`), decide how
    /// many leading tokens to keep and how many to trim. Extracted from
    /// `generateInline` so the index arithmetic is unit-testable without a model.
    struct InlinePrefillPlan: Equatable {
        /// Leading tokens shared with the cache — kept, never re-prefilled.
        let commonPrefix: Int
        /// Tokens to trim off the cache (it held more / divergent tail).
        let trim: Int
    }

    static func inlinePrefillPlan(previous: [Int], current: [Int]) -> InlinePrefillPlan {
        var cp = 0
        let bound = min(previous.count, current.count)
        while cp < bound && previous[cp] == current[cp] { cp += 1 }
        // Always re-prefill at least the final token so there is something to drive
        // decoding from — never reuse the entire prompt verbatim.
        if cp >= current.count { cp = max(0, current.count - 1) }
        return InlinePrefillPlan(commonPrefix: cp, trim: max(0, previous.count - cp))
    }

    /// Pure path-selection gate for the inline-completion entry point (WS2): given
    /// whether the speculative-decoding *preference* is on and whether the draft model
    /// is *actually loaded*, decide if the speculative path may run. Extracted so the
    /// gate is unit-testable without a model — the speculative path is taken iff BOTH
    /// hold (preference on AND draft resident). On a `false` here the caller routes to
    /// the proven single-model `generateInline`. Note this only decides *eligibility*;
    /// `generateInlineSpeculative` still falls back at *run time* on any decode failure
    /// (tokenizer mismatch, non-trimmable KV cache, etc.), so a `true` is never worse
    /// than the single-model path.
    static func shouldUseSpeculative(enabled: Bool, draftLoaded: Bool) -> Bool {
        enabled && draftLoaded
    }

    /// KV-cache quantization bits read once from preferences. `0`/unset = off
    /// (full-precision cache, the proven default). When set (e.g. 4 or 8), the
    /// library quantizes the KV cache after `quantizedKVStart` tokens, cutting
    /// inline memory and speeding long-context decode. mlx-swift-lm exposes this
    /// on `GenerateParameters` (`kvBits`/`kvGroupSize`/`quantizedKVStart`).
    nonisolated private static var configuredKVBits: Int { Preferences.inlineKVBits }

    nonisolated private static func makeParameters(
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        repetitionPenalty: Float?,
        kvBits: Int? = nil
    ) -> GenerateParameters {
        var parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )
        if let repetitionPenalty {
            parameters.repetitionPenalty = repetitionPenalty
        }
        if let kvBits, kvBits > 0 {
            parameters.kvBits = kvBits
        }
        return parameters
    }

    func generate(
        prompt: String,
        system: String?,
        maxTokens: Int,
        temperature: Float,
        repetitionPenalty: Float? = nil,
        topP: Float = 1.0,
        stop: [String] = [],
        maxWords: Int = 0
    ) async throws -> String {
        activeGenerations += 1
        defer { endGeneration() }
        guard let container else { throw MLXEngineError.notLoaded }

        let parameters = Self.makeParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty
        )

        // Superseded-request fast-out: this actor serializes generations, so a
        // request the user already invalidated (next keystroke) may be sitting in
        // the mailbox behind a running one. If the calling Task was cancelled
        // before we even start, skip the work entirely — no prefill, no decode.
        if Task.isCancelled { return "" }

        // Build the chat + UserInput *inside* the perform closure: UserInput is
        // non-Sendable, so it must not be captured across the @Sendable boundary.
        let output = try await withMLXErrorGuard("generate") { mlxError in
            try await container.perform { context in
            var messages: [Chat.Message] = []
            if let system, !system.isEmpty {
                messages.append(.system(system))
            }
            messages.append(.user(prompt))
            let userInput = UserInput(chat: messages)

            var lmInput = try await context.processor.prepare(input: userInput)
            // Trim the prompt to the speed/size ceiling, keeping the most recent
            // tokens. (The processor's tokens are 1-D, the rank the library expects.)
            let cap = Self.maxPromptTokens
            let seqLen = lmInput.text.tokens.dim(-1)
            if seqLen > cap {
                let start = seqLen - cap
                let trimmed = lmInput.text.tokens[.ellipsis, start ..< seqLen]
                lmInput = LMInput(tokens: trimmed)
            }
            // Prefill done. If a newer keystroke invalidated this request while we
            // prefilled, bail before decoding a single token — the dominant CPU
            // saving when the user is typing quickly.
            if Task.isCancelled { return "" }

            // Accumulate the streamed chunks into the full output, breaking early
            // on any stop sequence (keeps inline completions to one clause).
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context
            )
            outer: for await generation in stream {
                // Stop decoding the moment this request is superseded. Without this
                // each typed character left its now-useless generation running to
                // the word cap, stacking GPU work and pinning CPU while typing.
                if Task.isCancelled { break outer }
                // An MLX runtime error mid-decode means every further token is
                // garbage — bail immediately (the guard throws on scope exit).
                if mlxError.message != nil { break outer }
                if let chunk = generation.chunk {
                    text += chunk
                    for s in stop where !s.isEmpty {
                        if let r = text.range(of: s) {
                            text = String(text[..<r.lowerBound])
                            break outer
                        }
                    }
                    // Word cap: stop as soon as the (maxWords+1)th word begins,
                    // keeping exactly maxWords words. Inline accept is word-by-word
                    // (Tab), so a short suggestion appears fast and the user walks it.
                    if let capped = Self.wordCapped(text, maxWords: maxWords) {
                        text = capped
                        break outer
                    }
                }
            }
            return text
            }
        }

        // NOTE: we deliberately do NOT call `MLX.GPU.clearCache()` here. The cache
        // pool is already bounded by `configureMemoryLimits()` (384 MB), and the
        // pool is exactly the reusable scratch/KV buffers that make the *next*
        // completion's prefill fast. Clearing it after every keystroke forced each
        // inline completion to pay a near-cold prefill — a major latency source.
        // The bound caps memory without throwing away that reuse.
        return output
    }

    /// One conversation turn for the agent chat path. `Sendable` so it can cross the
    /// `AsyncThrowingStream` Task boundary (the library's `Chat.Message`/`UserInput`
    /// are not Sendable, so we carry a flat value type and build the real messages
    /// *inside* the generation closure — same discipline as `generate()`).
    /// `role` is an OpenAI role string: "system" | "user" | "assistant" | "tool".
    struct ChatTurn: Sendable, Equatable {
        let role: String
        let content: String
    }

    /// Multi-turn chat generation with optional tool specs, **streaming** decoded
    /// text chunks. This backs the coding-agent OpenAI-compatible endpoint
    /// (`ProsperLLMServer`): it renders the full `messages` array (including prior
    /// assistant tool-call turns and tool-result turns, already serialized into the
    /// model's native syntax by the caller) plus `tools` through the model's Jinja
    /// chat template, then streams raw decoded text. Tool-call *parsing* happens in
    /// the server (`ToolCallParser`) — this method only produces text.
    ///
    /// Unlike `generate()` this applies **no prompt-token cap** (agent context
    /// legitimately exceeds the inline 480-token window) and no word cap (agent
    /// turns decode long). Honors `stop` sequences and task cancellation.
    nonisolated func generateChat(
        messages: [ChatTurn],
        tools: [ToolSpec],
        maxTokens: Int,
        temperature: Float,
        topP: Float = 1.0,
        repetitionPenalty: Float? = nil,
        stop: [String] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamChat(
                        messages: messages, tools: tools, maxTokens: maxTokens,
                        temperature: temperature, topP: topP,
                        repetitionPenalty: repetitionPenalty, stop: stop,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamChat(
        messages: [ChatTurn],
        tools: [ToolSpec],
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        repetitionPenalty: Float?,
        stop: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Tracked like the other generation paths so a forced unload mid-stream defers.
        activeGenerations += 1
        defer { endGeneration() }
        guard let container else { throw MLXEngineError.notLoaded }
        let parameters = Self.makeParameters(
            maxTokens: maxTokens, temperature: temperature, topP: topP,
            repetitionPenalty: repetitionPenalty
        )
        if Task.isCancelled { return }
        let box = chatBox

        do {
            _ = try await withMLXErrorGuard("generateChat") { mlxError in
            try await container.perform { context in
                // Build Chat.Message inside the closure (non-Sendable types).
                let chat: [Chat.Message] = messages.map { turn in
                    switch turn.role {
                    case "system": return .system(turn.content)
                    case "assistant": return .assistant(turn.content)
                    case "tool": return .tool(turn.content)
                    default: return .user(turn.content)
                    }
                }
                let userInput = UserInput(
                    chat: chat, tools: tools.isEmpty ? nil : tools
                )
                let lmInput = try await context.processor.prepare(input: userInput)
                if Task.isCancelled { return 0 }
                let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)
                guard !promptTokens.isEmpty else { return 0 }

                // Prompt-prefix KV-cache reuse (same scheme as `generateInline`,
                // see `chatBox`). The cache is *stolen* from the box for the
                // duration of the request so a concurrent request can never trim
                // the same live cache — it just pays a fresh prefill.
                var cache: [KVCache]
                var prefill: [Int]
                let prior = box.caches
                let priorTokens = box.tokens
                box.reset()
                if let prior, canTrimPromptCache(prior) {
                    cache = prior
                    let plan = Self.inlinePrefillPlan(previous: priorTokens, current: promptTokens)
                    if plan.trim > 0 { trimPromptCache(cache, numTokens: plan.trim) }
                    prefill = Array(promptTokens[plan.commonPrefix...])
                } else {
                    cache = context.model.newCache(parameters: parameters)
                    prefill = promptTokens
                }
                let reusedPrefix = promptTokens.count - prefill.count
                let t0 = DispatchTime.now()

                // Raw-token generation + our own detokenization — deliberately NOT
                // `MLXLMCommon.generate`. That high-level path runs a
                // `TextToolTokenLoopHandler` which intercepts the model's native
                // `<tool_call>` tokens into typed `.toolCall` Generations and
                // SUPPRESSES the surrounding text; on long prompts (where the model
                // opens with the native `<tool_call>` token) it can swallow the whole
                // turn and emit nothing. The agent server owns tool-call parsing from
                // raw text (`ToolCallParser`), so we want the unmodified stream — the
                // same bytes `mlx_lm.stream_generate` would yield (special tokens
                // included, since `decode` keeps them). `<tool_call>…</tool_call>`
                // therefore reaches `ToolCallParser` intact.
                var emitted = ""
                var sentCount = 0
                var generated: [Int] = []
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                let stream = try MLXLMCommon.generateTokens(
                    input: LMInput(tokens: MLXArray(prefill)), cache: cache,
                    parameters: parameters, context: context
                )
                outer: for await generation in stream {
                    if Task.isCancelled { break outer }
                    if mlxError.message != nil { break outer }
                    guard let token = generation.token else { continue }
                    generated.append(token)
                    detokenizer.append(token: token)
                    guard let chunk = detokenizer.next() else { continue }
                    emitted += chunk
                    if !stop.isEmpty {
                        var cutAt: String.Index? = nil
                        for s in stop where !s.isEmpty {
                            if let r = emitted.range(of: s) {
                                if cutAt == nil || r.lowerBound < cutAt! { cutAt = r.lowerBound }
                            }
                        }
                        if let cutAt {
                            let kept = String(emitted[..<cutAt])
                            if kept.count > sentCount {
                                let start = kept.index(kept.startIndex, offsetBy: sentCount)
                                continuation.yield(String(kept[start...]))
                            }
                            break outer
                        }
                    }
                    continuation.yield(chunk)
                    sentCount = emitted.count
                }

                if Self.agentTimingEnabled {
                    let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
                    NSLog("prosper agent: reused \(reusedPrefix)/\(promptTokens.count) prompt tokens, "
                        + "prefilled \(prefill.count), decoded \(generated.count) tok in "
                        + "\(String(format: "%.0f", wallMs))ms")
                }

                // Persist the cache for the next request. It holds the prompt plus
                // every generated token that was fed back as input (`offset` is the
                // ground truth — the final token of a stopped stream was never fed).
                // The next request's prompt repeats this conversation verbatim, so
                // its common prefix covers nearly all of it.
                // Never persist after a cancelled stream: the producer may have
                // advanced the KV cache past the last yielded token, so `known`
                // would mislabel what the cache actually holds.
                if mlxError.message == nil, !Task.isCancelled {
                    let known = promptTokens + generated
                    let off = cache.first?.offset ?? 0
                    if canTrimPromptCache(cache), off > 0, off <= known.count {
                        box.caches = cache
                        box.tokens = Array(known.prefix(off))
                    }
                }
                return 0
            }
            }
        } catch {
            // Self-heal (same as inline): an MLX runtime error can leave a reused
            // cache inconsistent; the box was already stolen/reset above, but make
            // sure nothing half-baked survives for the next request.
            box.reset()
            throw error
        }
    }

    /// Inline-completion generation with **prompt-prefix KV-cache reuse** — the
    /// deepest latency lever. Each keystroke's prompt shares a long prefix with the
    /// previous one (the situational/app/on-screen context, and all of the user's
    /// text except the few new characters); only the tail changes. Re-prefilling
    /// the whole ~480-token prompt every keystroke is the dominant cost. Instead we
    /// keep the `[KVCache]` alive between calls and re-prefill **only the tokens
    /// that differ** from the previously cached prompt:
    ///
    ///   1. Tokenize the full prompt via the chat template.
    ///   2. Find the longest common prefix with the tokens already in the cache.
    ///   3. Trim the cache back to that prefix (lossless while it hasn't rotated).
    ///   4. Prefill only the divergent suffix, then decode.
    ///   5. Trim the freshly generated tokens so the cache once again holds exactly
    ///      the prompt — ready for the next keystroke's prefix match.
    ///
    /// Robust by construction: any condition that makes reuse unsafe (no prior
    /// cache, model reload, or the sliding window having filled so the cache is no
    /// longer trimmable) falls back to a full fresh prefill — never worse than the
    /// stateless path. Honors the same cancellation checks as `generate`.
    func generateInline(
        prompt: String,
        system: String?,
        maxTokens: Int,
        temperature: Float,
        topP: Float = 1.0,
        stop: [String] = [],
        maxWords: Int = 0
    ) async throws -> String {
        guard let container else { throw MLXEngineError.notLoaded }
        if Task.isCancelled { return "" }

        let parameters = Self.makeParameters(
            maxTokens: maxTokens, temperature: temperature, topP: topP,
            repetitionPenalty: nil, kvBits: Self.configuredKVBits
        )
        let box = inlineBox
        // Cap the prompt for speed (shorter prefill → faster keystroke response) and
        // to stay within one prefill window chunk. The reuse path trims the persisted
        // cache back to exactly `promptTokens` after each keystroke so prefill stays
        // incremental. See `maxPromptTokens`.
        let maxPrompt = Self.maxPromptTokens

        do {
            return try await withMLXErrorGuard("inline") { mlxError in
                try await container.perform { context in
            // Tokenize the full prompt (system + user) through the chat template.
            var messages: [Chat.Message] = []
            if let system, !system.isEmpty { messages.append(.system(system)) }
            messages.append(.user(prompt))
            let prepared = try await context.processor.prepare(input: UserInput(chat: messages))
            var promptTokens = prepared.text.tokens.asArray(Int32.self).map(Int.init)
            // Prompt cap (same as `generate`): keep the most recent tokens for speed.
            if promptTokens.count > maxPrompt {
                promptTokens = Array(promptTokens.suffix(maxPrompt))
            }
            guard !promptTokens.isEmpty else { return "" }
            if Task.isCancelled { return "" }

            // Decide reuse vs. fresh prefill.
            var cache: [KVCache]
            var prefill: [Int]
            if let prior = box.caches, canTrimPromptCache(prior) {
                cache = prior
                let plan = Self.inlinePrefillPlan(previous: box.tokens, current: promptTokens)
                if plan.trim > 0 { trimPromptCache(cache, numTokens: plan.trim) }
                prefill = Array(promptTokens[plan.commonPrefix...])
            } else {
                cache = context.model.newCache(parameters: parameters)
                prefill = promptTokens
            }

            // Prefill only the divergent suffix against the (possibly reused) cache.
            // Tokens MUST be a 1-D `[N]` array: `LLMModel.prepare` and
            // `TokenIterator.step` add the batch axis themselves (`y[.newAxis, …]`
            // and `previous[text: .newAxis]`). Passing a 2-D `[1, N]` here double-adds
            // the axis → the model sees `[1, 1, N]`, Gemma 4's per-layer-embedding
            // reshape then reads outer dims `(1, 1)` while the array carries `N×8960`
            // elements, and MLX aborts uncatchably:
            //   Fatal error: [reshape] Cannot reshape array of size N×8960 into shape (1,1,35,256)
            // This is the typing crash ("shows nothing, CPU spikes, cold reload").
            let reusedPrefix = promptTokens.count - prefill.count
            let lmInput = LMInput(tokens: MLXArray(prefill))
            var text = ""
            var info: GenerateCompletionInfo?
            let t0 = DispatchTime.now()
            let stream = try MLXLMCommon.generate(
                input: lmInput, cache: cache, parameters: parameters, context: context
            )
            outer: for await generation in stream {
                if Task.isCancelled { break outer }
                // An MLX runtime error mid-decode means every further token is
                // garbage — bail immediately (the guard throws on scope exit).
                if mlxError.message != nil { break outer }
                if let chunk = generation.chunk {
                    text += chunk
                    for s in stop where !s.isEmpty {
                        if let r = text.range(of: s) {
                            text = String(text[..<r.lowerBound]); break outer
                        }
                    }
                    if let capped = Self.wordCapped(text, maxWords: maxWords) {
                        text = capped; break outer
                    }
                } else if let i = generation.info {
                    info = i
                }
            }
            // Objective timing, silent unless PROSPER_INLINE_TIMING is set. Logged on
            // EVERY path — including the early `break` on a stop sequence or word cap,
            // which is the common case for inline completions, so the `info`-only
            // numbers below would otherwise never appear. Wall-clock ms gives the
            // user-perceived latency directly; the cache reuse/prefill counts and the
            // per-phase `info` numbers (when the stream ran to natural end) attribute
            // it to prefill vs. decode.
            if Self.inlineTimingEnabled {
                let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
                var line = "prosper inline: reused \(reusedPrefix)/\(promptTokens.count) prompt tokens, "
                    + "prefilled \(prefill.count), \(text.count) chars out in "
                    + "\(String(format: "%.0f", wallMs))ms"
                    + (Task.isCancelled ? " (cancelled)" : "")
                if let info {
                    line += " [prefill \(String(format: "%.0f", info.promptTime * 1000))ms, "
                        + "decode \(info.generationTokenCount) tok in "
                        + "\(String(format: "%.0f", info.generateTime * 1000))ms]"
                }
                NSLog("%@", line)
            }

            // Restore the cache to exactly `promptTokens` by trimming the tokens we
            // just generated, so the next keystroke matches prompt-to-prompt. If the
            // window filled mid-decode (no longer trimmable), drop the cache and let
            // the next request rebuild — correctness over reuse.
            let off = cache.first?.offset ?? 0
            if canTrimPromptCache(cache), off >= promptTokens.count {
                if off > promptTokens.count {
                    trimPromptCache(cache, numTokens: off - promptTokens.count)
                }
                box.caches = cache
                box.tokens = promptTokens
            } else {
                box.reset()
            }
            return text
                }
            }
        } catch {
            // Self-heal: an MLX runtime error may have left the persisted inline
            // KV cache in an inconsistent state (e.g. keys/mask length mismatch
            // in attention). Drop it so the next keystroke rebuilds from a fresh
            // prefill instead of failing on every subsequent request.
            if case MLXEngineError.mlxRuntime = error { box.reset() }
            throw error
        }
    }

    /// **Single inline entry point** (WS2 gate). Callers (CoreBridge) invoke this and
    /// stay unchanged: it picks the decode path internally. Runs the speculative path
    /// iff `Preferences.speculativeDecodingEnabled` AND the draft model is resident
    /// (`Self.shouldUseSpeculative`); otherwise — and on ANY speculative failure — it
    /// uses the proven single-model `generateInline`. So enabling the feature is never
    /// worse than today: a missing/broken/incompatible draft transparently degrades.
    func generateInlineRouted(
        prompt: String,
        system: String?,
        maxTokens: Int,
        temperature: Float,
        topP: Float = 1.0,
        stop: [String] = [],
        maxWords: Int = 0
    ) async throws -> String {
        // Tracked so a forced unload (autocomplete-disable) arriving mid-completion
        // defers instead of freeing GPU buffers under the inline compute. Cost is two
        // integer ops on the actor — negligible against multi-ms inference.
        activeGenerations += 1
        defer { endGeneration() }
        if Self.shouldUseSpeculative(
            enabled: Preferences.speculativeDecodingEnabled,
            draftLoaded: draftContainer != nil
        ) {
            return try await generateInlineSpeculative(
                prompt: prompt, system: system, maxTokens: maxTokens,
                temperature: temperature, topP: topP, stop: stop, maxWords: maxWords
            )
        }
        return try await generateInline(
            prompt: prompt, system: system, maxTokens: maxTokens,
            temperature: temperature, topP: topP, stop: stop, maxWords: maxWords
        )
    }

    /// Inline-completion generation via the library's **turnkey speculative decoding**
    /// (WS2). The draft model proposes `Preferences.numDraftTokens` cheap tokens per
    /// round; the main (verifier) model accepts/rejects them in a single forward pass.
    /// We do NOT hand-roll the accept/verify loop — `MLXLMCommon.generate(… draftModel:)`
    /// (backed by `SpeculativeTokenIterator`) owns it. We only supply both models, build
    /// the same prompt as `generateInline`, and consume the SAME `.chunk` stream with the
    /// SAME `wordCapped` / `stop` / `Task.isCancelled` early-exits.
    ///
    /// FALLBACK (never worse than today): on ANY failure — draft not loaded, the
    /// `SpeculativeTokenIterator` init throwing `KVCacheError` because a cache is not
    /// trimmable, a tokenizer mismatch surfacing at decode, or any other thrown error —
    /// this transparently re-runs the proven single-model `generateInline`.
    ///
    /// TOKENIZER-MATCH REQUIREMENT (critical): the draft and main models MUST share the
    /// exact same tokenizer or the verifier mis-maps the draft's token ids onto its own
    /// logits and decode throws / produces garbage. This cannot be cheaply validated at
    /// load time; a wrong `Preferences.draftModelId` surfaces only here, at which point
    /// we fall back. See `Preferences.defaultDraftModelId` (the 4-bit sibling of the
    /// default 6-bit main model — same Gemma 4 E2B `tokenizer.model`).
    ///
    /// MEMORY: this requires a SECOND resident model (the draft). Its weights live in
    /// *active* memory; the 384 MB `configureMemoryLimits()` cap only bounds the transient
    /// GPU buffer pool, not weights — so enabling speculative decoding materially raises RSS.
    ///
    /// CACHE NOTE: the speculative iterator owns its own main+draft KV caches; we do a
    /// fresh prefill per request and do NOT reuse the `InlineCacheBox` prefix cache (the
    /// non-speculative path keeps its prefix reuse, untouched).
    /// TODO(WS2): unify with InlineCacheBox prefix reuse.
    func generateInlineSpeculative(
        prompt: String,
        system: String?,
        maxTokens: Int,
        temperature: Float,
        topP: Float = 1.0,
        stop: [String] = [],
        maxWords: Int = 0
    ) async throws -> String {
        guard let container, let draftContainer else {
            // Draft (or main) not loaded — fall back to the single-model path.
            return try await generateInline(
                prompt: prompt, system: system, maxTokens: maxTokens,
                temperature: temperature, topP: topP, stop: stop, maxWords: maxWords
            )
        }
        if Task.isCancelled { return "" }

        let parameters = Self.makeParameters(
            maxTokens: maxTokens, temperature: temperature, topP: topP,
            repetitionPenalty: nil, kvBits: Self.configuredKVBits
        )
        let maxPrompt = Self.maxPromptTokens
        let numDraft = Preferences.numDraftTokens

        do {
            // Build + cap the LMInput up front, outside any `perform`. `prepare` returns
            // a `sending LMInput`, so the (non-Sendable) input crosses isolation safely.
            var messages: [Chat.Message] = []
            if let system, !system.isEmpty { messages.append(.system(system)) }
            messages.append(.user(prompt))
            var lmInput = try await container.prepare(input: UserInput(chat: messages))
            // Prompt cap (same as `generateInline`): keep the most recent tokens.
            let seqLen = lmInput.text.tokens.dim(-1)
            if seqLen > maxPrompt {
                let start = seqLen - maxPrompt
                let trimmed = lmInput.text.tokens[.ellipsis, start ..< seqLen]
                lmInput = LMInput(tokens: trimmed)
            }
            if Task.isCancelled { return "" }

            // `SpeculativeTokenIterator` needs BOTH models in one isolation domain. We
            // nest the two `perform`s and thread the non-Sendable values *as parameters*
            // (via the `nonSendable:`/`values:` overloads) rather than capturing them,
            // so the `@Sendable` closures don't capture each other's `ModelContext`.
            // Outer = main container (gives `context`); inner = draft container (gives
            // `draftContext`), into which we pass the main `context` + prepared `lmInput`.
            return try await withMLXErrorGuard("speculative") { mlxError in
                try await container.perform(nonSendable: lmInput) { context, lmInput in
                // Bundle the (non-Sendable) main context + prepared input so the inner
                // draft closure receives them as a single parameter instead of capturing.
                try await draftContainer.perform(nonSendable: (context, lmInput)) { draftContext, main in
                    let (mainContext, lmInput) = main
                    if Task.isCancelled { return "" }
                    // Turnkey speculative decoding: SpeculativeTokenIterator owns the
                    // accept/verify loop. Caches are nil → the iterator builds fresh,
                    // trimmable main+draft caches. Throws KVCacheError if a cache turns
                    // out non-trimmable, caught by the outer `catch` → fallback.
                    var text = ""
                    let stream = try MLXLMCommon.generate(
                        input: lmInput, parameters: parameters, context: mainContext,
                        draftModel: draftContext.model, numDraftTokens: numDraft
                    )
                    outer: for await generation in stream {
                        if Task.isCancelled { break outer }
                        if mlxError.message != nil { break outer }
                        if let chunk = generation.chunk {
                            text += chunk
                            for s in stop where !s.isEmpty {
                                if let r = text.range(of: s) {
                                    text = String(text[..<r.lowerBound]); break outer
                                }
                            }
                            if let capped = Self.wordCapped(text, maxWords: maxWords) {
                                text = capped; break outer
                            }
                        }
                    }
                    return text
                }
                }
            }
        } catch {
            // ANY speculative failure (KVCacheError "requires trimmable caches",
            // tokenizer mismatch, etc.) degrades to the proven single-model path —
            // never worse than today.
            if Self.inlineTimingEnabled {
                NSLog("prosper inline: speculative failed (%@), falling back", "\(error)")
            }
            return try await generateInline(
                prompt: prompt, system: system, maxTokens: maxTokens,
                temperature: temperature, topP: topP, stop: stop, maxWords: maxWords
            )
        }
    }

    // MARK: - LoRA adapter serving (WS6)

    /// True once a trained LoRA adapter has been loaded into the live serving model.
    private(set) var isAdapterLoaded = false

    /// Load the trained LoRA adapter from the per-model adapter directory into the
    /// live serving model (WS6). Best-effort: any failure (no adapter dir, missing
    /// weights, incompatible config) is logged and ignored — inference continues on
    /// the base model. Idempotent: a no-op once loaded.
    func loadAdapter() async {
        guard !isAdapterLoaded, let container else { return }
        let id = modelId
        let dir: URL
        do {
            dir = try LoRATrainer.adapterDirectory(for: id)
        } catch {
            NSLog("prosper-lora: adapter dir unavailable: %@", "\(error)")
            return
        }
        // Require both files before touching the model.
        let fm = FileManager.default
        let weights = dir.appendingPathComponent("adapters.safetensors")
        let config = dir.appendingPathComponent("adapter_config.json")
        guard fm.fileExists(atPath: weights.path), fm.fileExists(atPath: config.path) else {
            NSLog("prosper-lora: no adapter to serve at %@", dir.path)
            return
        }
        let loaded: Bool = await container.perform { context in
            do {
                let adapter = try LoRAContainer.from(directory: dir)
                try context.model.load(adapter: adapter)
                return true
            } catch {
                NSLog("prosper-lora: adapter load failed: %@", "\(error)")
                return false
            }
        }
        if loaded {
            isAdapterLoaded = true
            inlineBox.reset()  // adapter changes the model's outputs; drop primed cache
            chatBox.reset()
            NSLog("prosper-lora: adapter loaded for %@", id)
        }
    }

    /// Unload the LoRA adapter from the live serving model (WS6), restoring the base
    /// model. Best-effort + idempotent. Called by the A/B auto-disable guard.
    func unloadAdapter() async {
        guard isAdapterLoaded, let container else { return }
        let id = modelId
        guard let dir = try? LoRATrainer.adapterDirectory(for: id) else {
            isAdapterLoaded = false
            return
        }
        await container.perform { context in
            if let adapter = try? LoRAContainer.from(directory: dir) {
                context.model.unload(adapter: adapter)
            }
        }
        isAdapterLoaded = false
        inlineBox.reset()
        chatBox.reset()
        NSLog("prosper-lora: adapter unloaded for %@", id)
    }

    /// One-shot warm-up: compiles the Metal kernels and primes the buffer pool so
    /// the first real completion isn't paid cold. Idempotent and best-effort —
    /// failures are swallowed (a cold first completion is the only downside).
    private var didWarmup = false
    func warmup() async {
        guard container != nil, !didWarmup else { return }
        didWarmup = true
        _ = try? await generate(
            prompt: "Hi", system: nil, maxTokens: 1, temperature: 0
        )
    }

    // MARK: - Vision (VLM) path

    /// Load the VLM (multimodal) container lazily. Idempotent. Uses the same
    /// checkpoint id but resolves through `VLMModelFactory` so the gemma4 vision
    /// tower is wired. Heavier than the text path — only invoked when the user
    /// enables screenshot/vision context.
    func loadVLM(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if vlmContainer != nil { return }
        if let vlmLoadTask {
            _ = try await vlmLoadTask.value
            return
        }
        let id = modelId
        let box = ProgressBox()
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(id: id)
            let downloader = #hubDownloader()
            let loader = #huggingFaceTokenizerLoader()
            return try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: loader,
                configuration: configuration
            ) { p in box.set(p) }
        }
        vlmLoadTask = task
        let poll = Self.startProgressPoll(box, modelId: id, fallback: "Downloading vision model\u{2026}", progress)
        do {
            vlmContainer = try await task.value
            poll.cancel()
            vlmLoadTask = nil
        } catch {
            poll.cancel()
            vlmLoadTask = nil
            throw error
        }
    }

    var isVLMLoaded: Bool { vlmContainer != nil }

    /// Single-shot multimodal generation: the prompt plus one screenshot image
    /// (the region around the caret) feed the gemma4 vision path. Loads the VLM
    /// container on first use. Falls back by throwing `notLoaded` if unavailable.
    func generateWithImage(
        prompt: String,
        system: String?,
        image: CIImage,
        maxTokens: Int,
        temperature: Float,
        repetitionPenalty: Float? = nil,
        topP: Float = 1.0,
        stop: [String] = [],
        maxWords: Int = 0
    ) async throws -> String {
        // Counted (held across loadVLM + the VLM compute) so a forced unload mid-OCR
        // defers instead of freeing vlmContainer under an active multimodal generation.
        activeGenerations += 1
        defer { endGeneration() }
        Self.configureMemoryLimits()
        try await loadVLM { _, _ in }
        guard let vlmContainer else { throw MLXEngineError.notLoaded }

        let parameters = Self.makeParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty
        )

        let output = try await withMLXErrorGuard("vlm") { mlxError in
            try await vlmContainer.perform { context in
            var messages: [Chat.Message] = []
            if let system, !system.isEmpty {
                messages.append(.system(system))
            }
            messages.append(.user(prompt, images: [.ciImage(image)]))
            let userInput = UserInput(chat: messages)

            let lmInput = try await context.processor.prepare(input: userInput)
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context
            )
            outer: for await generation in stream {
                if mlxError.message != nil { break outer }
                if let chunk = generation.chunk {
                    text += chunk
                    for s in stop where !s.isEmpty {
                        if let r = text.range(of: s) {
                            text = String(text[..<r.lowerBound])
                            break outer
                        }
                    }
                    // Word cap: stop as soon as the (maxWords+1)th word begins,
                    // keeping exactly maxWords words. Inline accept is word-by-word
                    // (Tab), so a short suggestion appears fast and the user walks it.
                    if let capped = Self.wordCapped(text, maxWords: maxWords) {
                        text = capped
                        break outer
                    }
                }
            }
            return text
            }
        }
        // Vision prefill allocates large image-feature buffers; release them
        // immediately so they don't pin memory until the next VLM call.
        MLX.GPU.clearCache()
        return output
    }
}
