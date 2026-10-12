import Foundation
import os.lock

/// Enforces **one resident LLM at a time**. The inline-completion model
/// (`MLXEngine.shared`, multi-GB) and the coding-agent model (also multi-GB) cannot
/// both be resident on a typical 16–32 GB Mac, so they are mutually exclusive:
///
///   • `acquireAgent()` frees the inline model and loads the agent model.
///   • `releaseAgent()` frees the agent model; the inline model reloads **lazily**
///     on the next keystroke (`MLXEngine.load()` is idempotent + lazy — see
///     MLXEngine.swift:392), so no eager reload is needed here.
///
/// While agent mode is active, the inline hot path (`CoreBridge.complete`) early-outs
/// via `isAgentActive` so it never races a reload against the agent's weights.
///
/// The agent runs on its OWN `MLXEngine` instance (its own `modelId`), NOT via
/// `MLXEngine.shared.prepareSwitch` — switching the shared engine would clobber the
/// user's inline `coreModel` selection.
actor ModelResidencyCoordinator {
    static let shared = ModelResidencyCoordinator()

    /// Frees the inline engines and loads the agent engine for a model id. Test seam:
    /// the default is the real load; tests pass a fake so no model is ever touched.
    typealias MakeEngine = @Sendable (
        _ modelId: String, _ progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> any AgentChatEngine
    private let makeEngine: MakeEngine

    init(makeEngine: @escaping MakeEngine = ModelResidencyCoordinator.loadAgentEngine) {
        self.makeEngine = makeEngine
    }

    enum Mode: Sendable, Equatable { case inline, agent }
    private(set) var mode: Mode = .inline

    /// The agent engine, resident only in `.agent` mode. Either the llama.cpp
    /// engine (GGUF catalog rows) or a dedicated `MLXEngine` (HF snapshot rows).
    private var agent: (any AgentChatEngine)?

    /// Cheap, lock-guarded snapshot of "is the agent model resident", readable from
    /// the inline hot path without an actor hop. `OSAllocatedUnfairLock` is the
    /// lightest correct primitive available on macOS 14 (no `Synchronization.Atomic`
    /// until macOS 15).
    /// Internal (not private) only so tests can restore it: it is static, shared by
    /// every instance including `shared`.
    static let activeFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// True while the agent model is (being) loaded/resident. Inline completion
    /// consults this and skips generation so it never fights the agent for memory.
    nonisolated static var isAgentActive: Bool { activeFlag.withLock { $0 } }

    /// In-flight load, shared by concurrent acquirers. Without this, two callers
    /// (e.g. `warmUp` on window open racing the first `submit`) both pass the
    /// `mode == .agent` check while the first is suspended in `load` and each
    /// loads its own multi-GB engine.
    private var acquireTask: Task<any AgentChatEngine, Error>?
    /// Progress callbacks of every waiter on the in-flight load (a later caller
    /// must still see download progress — the chat UI's loading bar).
    private var progressSinks: [@Sendable (Double, String) -> Void] = []
    /// Bumped by `releaseAgent`; a load that finishes after a release must not
    /// resurrect agent mode (window already closed).
    private var epoch = 0
    /// The in-flight release: unloads the engine `releaseAgent` took out of service and
    /// waits out (then unloads) the load it cancelled. Every new load awaits it first, so
    /// the dying engine is never handed out, never resident beside its successor, and
    /// never unloaded after the successor loaded (the GGUF engine is ONE singleton).
    private var releasing: Task<Void, Never>?

    /// Enter agent mode. Unloads the inline model, then loads the configured agent
    /// model on a dedicated engine. Idempotent + coalescing: returns the live agent
    /// engine if already in agent mode, joins the in-flight load otherwise.
    /// Progress is forwarded to every waiter (first-time downloads).
    ///
    /// On load failure the inline model is restored to "available" (it reloads
    /// lazily) and the error is rethrown — the caller surfaces it in the chat UI.
    func acquireAgent(
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> any AgentChatEngine {
        if mode == .agent, let agent { return agent }
        progressSinks.append(progress)
        let myEpoch = epoch
        let task: Task<any AgentChatEngine, Error>
        if let acquireTask {
            task = acquireTask
        } else {
            Self.activeFlag.withLock { $0 = true }
            let modelId = Preferences.agentModel
            let pending = releasing
            // Strong capture: the closure dies with the load.
            task = Task {
                // Never load beside (or under) a release still unloading.
                await pending?.value
                try Task.checkCancellation()
                return try await makeEngine(modelId) { p, s in
                    Task { await self.fanProgress(p, s) }
                }
            }
            acquireTask = task
        }
        do {
            let engine = try await task.value
            guard epoch == myEpoch else {
                // Released (window closed) while loading — don't resurrect, and don't
                // unload: the release that moved the epoch owns this engine (its
                // `releasing` unloads it before any newer load starts). Unloading here
                // could hit `LlamaAgentEngine.shared` after a newer acquire loaded it.
                throw CancellationError()
            }
            agent = engine
            mode = .agent
            acquireTask = nil
            progressSinks = []
            return engine
        } catch {
            if epoch == myEpoch {
                Self.activeFlag.withLock { $0 = false }
                mode = .inline
                acquireTask = nil
                progressSinks = []
            }
            throw error
        }
    }

    private func fanProgress(_ p: Double, _ s: String) {
        for sink in progressSinks { sink(p, s) }
    }

    /// Leave agent mode: free the agent model's weights. The inline model is NOT
    /// eagerly reloaded — it comes back lazily on the next completion request.
    func releaseAgent() async {
        epoch += 1
        let loading = acquireTask
        loading?.cancel()
        acquireTask = nil
        progressSinks = []
        // Out of service before the first await: the fast path must not hand a new
        // run the engine being unloaded (#411 R1).
        let dying = agent
        agent = nil
        mode = .inline
        if dying != nil || loading != nil {
            let prior = releasing
            let release = Task {
                await prior?.value
                await dying?.unload()
                // A cancelled load may still finish; its engine is ours to free.
                if let engine = try? await loading?.value { await engine.unload() }
            }
            releasing = release
            await release.value
            if releasing == release { releasing = nil }
        }
        // Only if nothing newer started meanwhile (an acquire may be waiting on us).
        if agent == nil, acquireTask == nil, releasing == nil {
            Self.activeFlag.withLock { $0 = false }
        }
    }

    /// The real load: one resident at a time, so free BOTH inline engines (MLX and
    /// llama.cpp — ~3 GB) before the multi-GB agent model loads. The inline model
    /// reloads lazily on the first keystroke after release.
    static func loadAgentEngine(
        modelId: String, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> any AgentChatEngine {
        await MLXEngine.shared.unload()
        await LlamaInlineEngine.shared.unload()
        if let gguf = AgentModelRegistry.gguf(for: modelId) {
            try await LlamaAgentEngine.shared.ensureModel(gguf, progress: progress)
            return LlamaAgentEngine.shared
        }
        let engine = MLXEngine(modelId: modelId)
        try await engine.load(progress: progress)
        return engine
    }

    /// The live agent engine, if resident (nil in inline mode).
    func currentAgentEngine() -> (any AgentChatEngine)? { agent }
}
