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

    enum Mode: Sendable, Equatable { case inline, agent }
    private(set) var mode: Mode = .inline

    /// The agent engine, resident only in `.agent` mode.
    private var agent: MLXEngine?

    /// Cheap, lock-guarded snapshot of "is the agent model resident", readable from
    /// the inline hot path without an actor hop. `OSAllocatedUnfairLock` is the
    /// lightest correct primitive available on macOS 14 (no `Synchronization.Atomic`
    /// until macOS 15).
    private static let activeFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// True while the agent model is (being) loaded/resident. Inline completion
    /// consults this and skips generation so it never fights the agent for memory.
    nonisolated static var isAgentActive: Bool { activeFlag.withLock { $0 } }

    /// In-flight load, shared by concurrent acquirers. Without this, two callers
    /// (e.g. `warmUp` on window open racing the first `submit`) both pass the
    /// `mode == .agent` check while the first is suspended in `load` and each
    /// loads its own multi-GB engine.
    private var acquireTask: Task<MLXEngine, Error>?
    /// Progress callbacks of every waiter on the in-flight load (a later caller
    /// must still see download progress — the chat UI's loading bar).
    private var progressSinks: [@Sendable (Double, String) -> Void] = []
    /// Bumped by `releaseAgent`; a load that finishes after a release must not
    /// resurrect agent mode (window already closed).
    private var epoch = 0

    /// Enter agent mode. Unloads the inline model, then loads the configured agent
    /// model on a dedicated engine. Idempotent + coalescing: returns the live agent
    /// engine if already in agent mode, joins the in-flight load otherwise.
    /// Progress is forwarded to every waiter (first-time downloads).
    ///
    /// On load failure the inline model is restored to "available" (it reloads
    /// lazily) and the error is rethrown — the caller surfaces it in the chat UI.
    func acquireAgent(
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> MLXEngine {
        if mode == .agent, let agent { return agent }
        progressSinks.append(progress)
        let myEpoch = epoch
        let task: Task<MLXEngine, Error>
        if let acquireTask {
            task = acquireTask
        } else {
            Self.activeFlag.withLock { $0 = true }
            let modelId = Preferences.agentModel
            // Strong capture: `self` is a process-lifetime singleton and the closure
            // dies with the load.
            task = Task {
                await MLXEngine.shared.unload()
                let engine = MLXEngine(modelId: modelId)
                try await engine.load { p, s in
                    Task { await ModelResidencyCoordinator.shared.fanProgress(p, s) }
                }
                return engine
            }
            acquireTask = task
        }
        do {
            let engine = try await task.value
            guard epoch == myEpoch else {
                // Released (window closed) while loading — don't resurrect.
                await engine.unload()
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
        acquireTask?.cancel()
        acquireTask = nil
        progressSinks = []
        await agent?.unload()
        agent = nil
        mode = .inline
        Self.activeFlag.withLock { $0 = false }
    }

    /// The live agent engine, if resident (nil in inline mode).
    func currentAgentEngine() -> MLXEngine? { agent }
}
