import Foundation
import CryptoKit
import os.log
import Observation

/// Drives one coding-agent session end to end and exposes its state to the UI.
///
/// Responsibilities:
///   • bring up `ProsperLLMServer` (in-process MLX inference endpoint),
///   • flip `ModelResidencyCoordinator` into agent mode (unload inline Gemma, load the
///     coding model) — warmed up on window open so the first prompt doesn't wait,
///   • spawn + own a `CodingHarness` (Codex first), pump its event stream into a
///     `@Published` transcript, and surface approvals,
///   • on turn completion, release the agent model so inline completions resume.
///
/// `@MainActor` because it is the view model for `ChatWindow`; all harness/engine work
/// happens off-main inside the actors it calls.
@MainActor
@Observable
final class AgentController {
    static let shared = AgentController()

    @ObservationIgnored
    private let log = Logger(subsystem: "com.prosper.app", category: "AgentController")

    // MARK: Observed UI state
    //
    // `@Observable` (not `ObservableObject`): tracking is per-property, so a view only
    // re-renders for the fields it actually reads. Streaming bumps `items` ~50×/s — with
    // object-level `ObservableObject` that re-ran every view holding the controller
    // (incl. the AppKit-backed composer's `updateNSView`), which froze the window. Now
    // only views reading `items`/`transcriptRevision` re-run; the composer/header don't.

    private(set) var items: [AgentItem] = [] {
        // Cheap change signal: every mutation (append OR in-place streamed delta) bumps
        // this. The transcript view observes it for auto-follow instead of diffing the
        // whole `items` array (Equatable) on every token — O(1) vs O(n) per delta.
        didSet { transcriptRevision &+= 1 }
    }
    /// Monotonic counter, bumped on any `items` mutation. See `items.didSet`.
    private(set) var transcriptRevision = 0
    private(set) var phase: Phase = .idle
    /// When the current working session started (idle → working). Drives the live
    /// "Working… 12s" elapsed readout and the "Finished in …" footnote. Set on a fresh
    /// prompt, kept across queued follow-ups (same working session), cleared when done.
    private(set) var runStartedAt: Date?
    private(set) var pendingApprovals: [ApprovalRequest] = []
    /// Goals typed while a turn is in flight — not yet handed to the model. Shown as
    /// dimmed "queued" bubbles; flushed in order when the current turn finishes, or
    /// recalled into the composer with the ↑ key. Not persisted (transient pre-send).
    private(set) var queued: [QueuedMessage] = []
    private(set) var usage: TokenUsage?
    /// The on-screen session's history label — editable from the header. Mirrors the
    /// stored title; seeded from the first goal, or set on resume.
    private(set) var sessionTitle: String = ""
    var workingDirectory: String = Preferences.agentWorkingDirectory {
        didSet { Preferences.agentWorkingDirectory = workingDirectory }
    }

    /// The persisted row id for the on-screen session, if any (live thread or armed
    /// resume). nil before the first prompt of a fresh conversation creates a row.
    var currentSessionID: String? { session?.raw ?? pendingResumeID }

    struct QueuedMessage: Identifiable, Sendable, Equatable { let id = UUID(); var text: String }

    enum Phase: Equatable {
        case idle
        case loadingModel(progress: Double, status: String)
        case running
        case awaitingApproval
        case error(String)
    }

    var isActive: Bool {
        switch phase { case .idle, .error: return false; default: return true }
    }

    // MARK: Internals

    private var harness: CodingHarness?
    private var session: SessionID?
    private var currentTurn: TurnID?
    private var eventPump: Task<Void, Never>?
    /// itemID → index in `items`, for in-place delta accumulation.
    private var itemIndex: [String: Int] = [:]
    /// Set by `resume(_:)`: the persisted Codex thread id to re-attach on the next
    /// `ensureSession` instead of opening a fresh thread. Defers the model load until
    /// the user actually sends a follow-up prompt.
    private var pendingResumeID: String?
    /// Prompts queued via the `prosper agent` CLI. Unlike `queued` (follow-ups in
    /// the CURRENT session), each CLI job runs in its own fresh session, strictly
    /// after the previous turn completes; every one lands in history.
    private var cliQueue: [AgentCLI.Job] = []
    /// Consecutive silent auto-continues since the model last did real work. A local
    /// model often ends a turn narrating a next step it never performed; we re-enter
    /// the loop with a hidden "Continue." nudge. Bounded so a model that only narrates
    /// can't loop forever; reset to 0 the moment a real tool call / file change lands
    /// (mirrors Claude Code's `stop_hook_active` guard / opencode's `session.stopping`).
    private var autoNudges = 0
    /// Set when the MCP config file changes mid-turn; the harness is respawned (to pick
    /// up the new servers/hooks) once the turn drains. See `applyAgentConfigChange`.
    private var agentConfigDirty = false
    private static let maxAutoNudges = 2

    private init() {}

    // MARK: - Public API

    /// Submit a goal. Boots the server + agent model on first call, starts a session,
    /// and streams the run into `items`. Safe to call again to continue the session.
    func submit(goal: String, cwd: String? = nil) {
        if let cwd { workingDirectory = cwd }
        // Busy → queue it (visibly pending) rather than racing a second prompt into the
        // same in-flight turn. Flushed in order from `handleTurnCompleted`.
        if isActive {
            queued.append(QueuedMessage(text: goal))
            return
        }
        // Mark busy synchronously: `run` flips to .loadingModel only after its Task
        // is scheduled, leaving a window where a second submit would race a second
        // concurrent run instead of queueing.
        phase = .running
        runStartedAt = Date()   // fresh working session — start the elapsed clock at 0
        autoNudges = 0   // fresh user goal — auto-continue budget resets
        append(.user(id: UUID().uuidString, text: goal))
        Task { await run(goal: goal) }
    }

    /// Stamp the elapsed working time into the transcript as a footnote and stop the
    /// clock. No-ops if the clock isn't running (so a late `turn/completed` after a
    /// Stop can't double-post). Idempotent per working session.
    private func postElapsedNote() {
        guard let started = runStartedAt else { return }
        runStartedAt = nil
        let secs = max(0, Int(Date().timeIntervalSince(started).rounded()))
        append(.note(id: UUID().uuidString, text: "Finished in \(Self.formatDuration(secs))"))
    }

    /// Compact human duration: `12s`, `1m 23s`, `2h 5m`.
    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60, s = seconds % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }

    /// Pull the most recently queued (not-yet-sent) goal back out for editing — bound
    /// to the composer's ↑ key. Returns its text, or nil if nothing is queued.
    func recallLastQueued() -> String? {
        queued.popLast()?.text
    }

    /// Set the working directory for the next session. Takes effect on the next new
    /// session (an in-flight session keeps its original cwd).
    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    func respond(to approval: ApprovalRequest, decision: ApprovalDecision) {
        pendingApprovals.removeAll { $0.id == approval.id }
        if pendingApprovals.isEmpty, phase == .awaitingApproval { phase = .running }
        Task { try? await harness?.respondToApproval(approval.id, decision: decision) }
    }

    /// Abort the in-flight turn (the model stays resident for a follow-up prompt).
    /// Cancels the server-side generation directly for an instant GPU stop — codex's
    /// turn-interrupt alone may leave the HTTP request streaming (keep-alive pooling).
    /// With no session yet (model still loading), tears the run down entirely, which
    /// cancels the in-flight load and unloads.
    func stop() {
        ProsperLLMServer.shared.cancelActiveGenerations()
        let stale = pendingApprovals
        pendingApprovals.removeAll()
        if let harness, let session {
            let turn = currentTurn
            // Reflect the stop immediately. Generation is already cancelled server-side,
            // so nothing is working — don't wait on a codex `turn/completed`, which never
            // arrives for an interrupted turn (the activity indicator would hang). A late
            // completed event is idempotent; trailing stream deltas don't touch `phase`.
            currentTurn = nil
            if case .error = phase {} else { phase = .idle }
            Task {
                for req in stale { try? await harness.respondToApproval(req.id, decision: .cancel) }
                try? await harness.abort(session: session, turn: turn)
            }
        } else {
            Task { await end() }
        }
        // An interrupted turn emits no `turn/completed`, so handleTurnCompleted won't
        // fire — stamp the elapsed time here. No-ops if the clock already stopped.
        postElapsedNote()
        persistTranscript()
    }

    /// End the session entirely: shut the harness down and release the agent model so
    /// inline completions resume.
    func end() async {
        // Any teardown that bypasses handleTurnCompleted (Stop during model load,
        // setup failure, codex crash) must still halt the CLI queue — pending CLI
        // jobs firing on the NEXT drain kick would defeat the stop.
        if !cliQueue.isEmpty {
            log.warning("agent CLI queue dropped (\(self.cliQueue.count, privacy: .public) pending) — session torn down")
            cliQueue.removeAll()
        }
        eventPump?.cancel()
        eventPump = nil
        await harness?.shutdown()
        harness = nil
        session = nil
        currentTurn = nil
        await ModelResidencyCoordinator.shared.releaseAgent()
        // Keep an error phase visible (run() sets it just before tearing down) —
        // only a clean teardown returns to idle.
        if case .error = phase {} else { phase = .idle }
    }

    // MARK: - CLI queue (`prosper agent <prompt>`)

    /// Pull queued CLI prompts from the file inbox and start the next one if the
    /// agent is idle. Called at launch and on every distributed-notification kick.
    func drainCLIInbox() {
        let jobs = AgentCLI.takeInbox()
        guard !jobs.isEmpty else { return }
        cliQueue.append(contentsOf: jobs)
        ChatWindow.shared.show()
        runNextCLIJob()
    }

    /// Start the next CLI job in a FRESH session: snapshot the current transcript,
    /// detach the session (the new run opens its own Codex thread → its own history
    /// entry), clear the window, and submit.
    private func runNextCLIJob() {
        guard !isActive, !cliQueue.isEmpty else { return }
        let job = cliQueue.removeFirst()
        persistTranscript()
        session = nil
        currentTurn = nil
        pendingResumeID = nil
        items = []
        itemIndex.removeAll()
        usage = nil
        if case .error = phase { phase = .idle }
        submit(goal: job.prompt, cwd: job.cwd)
    }

    // MARK: - History / resume

    /// Recent persisted sessions, newest first, for the history picker.
    func recentSessions() async -> [AgentSessionStore.Summary] {
        await AgentSessionStore.shared.recentSessions()
    }

    /// Restore a persisted session: load its transcript for display and arm a lazy
    /// re-attach. The harness/model are NOT loaded here — the Codex thread is resumed
    /// on the next submitted prompt (see `ensureSession`). Refuses while a run is live.
    func resume(_ summary: AgentSessionStore.Summary) {
        guard !isActive else { return }
        Task {
            let restored = await AgentSessionStore.shared.loadTranscript(id: summary.id)
            items = restored
            rebuildItemIndex()
            queued = []
            pendingApprovals = []
            workingDirectory = summary.cwd
            pendingResumeID = summary.id
            session = nil
            currentTurn = nil
            usage = nil
            sessionTitle = summary.title
            phase = .idle
            ChatWindow.shared.show()
        }
    }

    /// Start a fresh conversation: snapshot the current transcript to the store,
    /// detach the session (next prompt opens a new Codex thread → its own history
    /// entry), and clear the window. Refuses while a run is live.
    func newSession() {
        guard !isActive else { return }
        persistTranscript()
        session = nil
        currentTurn = nil
        pendingResumeID = nil
        items = []
        itemIndex.removeAll()
        queued = []
        pendingApprovals = []
        usage = nil
        sessionTitle = ""
        phase = .idle
    }

    /// Delete a persisted session from disk. Refuses to nuke the one on screen.
    func deleteSession(_ summary: AgentSessionStore.Summary) async {
        guard summary.id != session?.raw, summary.id != pendingResumeID else { return }
        await AgentSessionStore.shared.deleteSession(id: summary.id)
    }

    /// Rename the on-screen session (its history label). Trims, ignores empties, and
    /// persists only if a row exists yet (a fresh conversation gets its title from the
    /// first goal — nothing to rename until then).
    func renameSession(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionTitle = trimmed
        guard let id = currentSessionID else { return }
        Task { await AgentSessionStore.shared.renameSession(id: id, title: trimmed) }
    }

    private func rebuildItemIndex() {
        itemIndex.removeAll(keepingCapacity: true)
        for (i, item) in items.enumerated() {
            if let id = item.itemID { itemIndex[id] = i }
        }
    }

    /// Snapshot the rendered transcript to the on-device store for the current session.
    private func persistTranscript() {
        guard let session else { return }
        let snapshot = items
        Task { await AgentSessionStore.shared.saveTranscript(id: session.raw, items: snapshot) }
    }

    // MARK: - Runner entry (`g ` command)

    /// Start a run from the runner's `g <goal>` command: open the agent window (so
    /// progress is visible and tool approvals can be answered) and submit the goal.
    /// No-op when busy (one resident coding model at a time) or the goal is empty.
    /// The run uses `workingDirectory` (Preferences.agentWorkingDirectory); the
    /// window's folder picker lets the user change it.
    func startFromRunner(goal: String) {
        guard !isActive else { return }
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ChatWindow.shared.show()
        submit(goal: trimmed)
    }

    // MARK: - Run

    private func run(goal: String) async {
        do {
            let harness = try await ensureHarness()
            let session = try await ensureSession(harness)
            phase = .running
            currentTurn = try await harness.sendPrompt(session: session, input: [.text(goal)])
        } catch is CancellationError {
            // Stop pressed while the model was still loading — `stop()` already tore
            // everything down; don't surface it as an error.
            if case .error = phase {} else { phase = .idle }
        } catch {
            log.error("agent run failed: \(String(describing: error), privacy: .public)")
            append(.error(id: UUID().uuidString, message: Self.describe(error)))
            phase = .error(Self.describe(error))
            // Capture the failure transcript before tearing down. A setup failure
            // (harness spawn / model load) has no session yet — mint one so the
            // failed run still lands in history instead of vanishing.
            if session == nil {
                let failed = SessionID(raw: "failed-" + UUID().uuidString)
                session = failed
                persistSessionMeta(failed)
            }
            persistTranscript()
            await end()
        }
    }

    private func ensureHarness() async throws -> CodingHarness {
        if let harness { return harness }

        // 1. Local inference endpoint.
        let (port, token) = try ProsperLLMServer.shared.start()
        let baseURL = "http://127.0.0.1:\(port)/v1"

        // 2. Resolve the codex helper — downloaded on first use (like the model), so a
        // fresh install that never opens the agent never pulls the ~86 MB binary. Do this
        // BEFORE the residency swap: a failed/slow download shouldn't have unloaded the
        // inline model for nothing.
        phase = .loadingModel(progress: 0, status: "Preparing coding agent…")
        let executable = try await Self.resolveCodexExecutable()

        // 3. Residency swap: unload inline model, load the coding model.
        phase = .loadingModel(progress: 0, status: "Loading \(Preferences.agentModel)…")
        _ = try await ModelResidencyCoordinator.shared.acquireAgent { [weak self] p, status in
            Task { @MainActor in
                // A late progress tick must not stomp a phase that already moved on
                // (running / error after the load finished or the run was stopped).
                guard let self, case .loadingModel = self.phase else { return }
                self.phase = .loadingModel(progress: p, status: status)
            }
        }

        // 4. Spawn the harness.
        let codexHome = Self.codexHomeURL()
        let harness = CodexHarness(executableURL: executable, codexHome: codexHome,
                                   llmBaseURL: baseURL, llmToken: token)
        try await harness.start()
        self.harness = harness
        pumpEvents(harness)
        return harness
    }

    private func ensureSession(_ harness: CodingHarness) async throws -> SessionID {
        if let session { return session }
        // Resuming a persisted session: re-attach the existing Codex thread rather
        // than opening a fresh one. The display transcript was already restored. If the
        // thread is gone from CODEX_HOME (evicted/cleared), fall back to a fresh session
        // so the follow-up prompt still runs instead of erroring the turn.
        if let resumeID = pendingResumeID {
            pendingResumeID = nil
            if let resumed = try? await harness.resumeSession(SessionID(raw: resumeID)) {
                self.session = resumed
                persistSessionMeta(resumed)
                return resumed
            }
            log.warning("resume of thread \(resumeID, privacy: .public) failed; starting a fresh session")
        }
        // Permissions (F4): bypass-all = no approvals + full filesystem; otherwise the
        // configured approval policy + a network-gated workspace-write sandbox.
        let policy: ApprovalPolicy
        let sandbox: SandboxPolicy
        if Preferences.agentBypassAll {
            policy = .never
            sandbox = .dangerFullAccess
        } else {
            policy = ApprovalPolicy(rawValue: Preferences.agentApprovalPolicy) ?? .onRequest
            sandbox = .workspaceWrite(networkAccess: Preferences.agentNetworkAccess)
        }
        let opts = SessionOptions(
            cwd: workingDirectory, model: Preferences.agentModel,
            approvalPolicy: policy, sandbox: sandbox
        )
        let session = try await harness.newSession(opts)
        self.session = session
        persistSessionMeta(session)
        return session
    }

    /// Persist (create/refresh) session metadata. Title = the first user goal.
    private func persistSessionMeta(_ session: SessionID) {
        // Prefer a title the user typed in the header; else derive from the first goal.
        let derived = items.first.flatMap { item -> String? in
            if case .user(_, let text) = item { return text }
            return nil
        } ?? "Coding session"
        let title = sessionTitle.isEmpty ? derived : sessionTitle
        if sessionTitle.isEmpty { sessionTitle = title }
        let cwd = workingDirectory
        let model = Preferences.agentModel
        let id = session.raw
        Task { await AgentSessionStore.shared.upsertSession(id: id, cwd: cwd, model: model, title: title) }
    }

    // MARK: - Event pump

    private func pumpEvents(_ harness: CodingHarness) {
        eventPump = Task { [weak self] in
            for await event in harness.events {
                guard let self else { return }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: HarnessEvent) {
        switch event {
        case .sessionStarted(let s):
            // Only adopt when nothing is tracked: a late/echoed event must not
            // clobber the session id history/persistence is keyed on.
            if session == nil { session = s }
        case .turnStarted(let t):
            currentTurn = t
            phase = .running
        case .textDelta(_, let itemID, let text):
            upsertText(itemID, text: text, reasoning: false)
        case .reasoningDelta(_, let itemID, let text):
            upsertText(itemID, text: text, reasoning: true)
        case .toolCallStarted(let call):
            autoNudges = 0   // model is doing real work — reset the nudge budget
            upsertToolCall(call, output: nil)
        case .toolCallOutput(let id, let chunk):
            appendToolOutput(id, chunk: chunk)
        case .toolCallCompleted(let call):
            // Completion carries the authoritative combined output (+ exit/duration
            // footer); replace any streamed deltas with it. nil only if absent.
            upsertToolCall(call, output: call.output)
        case .fileChange(_, let diff):
            autoNudges = 0   // model is doing real work — reset the nudge budget
            append(.fileDiff(id: UUID().uuidString, path: diff.path, diff: diff.unifiedDiff, change: diff.change))
        case .planUpdated(_, let steps):
            upsertPlan(steps)
        case .approvalRequest(let req):
            pendingApprovals.append(req)
            phase = .awaitingApproval
        case .usage(let u):
            usage = u
        case .turnCompleted(_, let outcome):
            handleTurnCompleted(outcome)
        case .error(let err):
            append(.error(id: UUID().uuidString, message: Self.describe(err)))
            phase = .error(Self.describe(err))
            // Process death never reaches handleTurnCompleted — halt the CLI queue
            // here so stopped/failed runs don't resurrect later jobs on the next kick.
            if !cliQueue.isEmpty {
                log.warning("agent CLI queue dropped (\(self.cliQueue.count, privacy: .public) pending) — harness error")
                cliQueue.removeAll()
            }
        }
    }

    private func handleTurnCompleted(_ outcome: TurnOutcome) {
        currentTurn = nil
        // A finished turn can't be approved anymore — drop stale requests so the
        // approval bar can't outlive the turn.
        pendingApprovals.removeAll()
        switch outcome {
        case .completed, .aborted:
            phase = .idle
        case .failed(let msg):
            append(.error(id: UUID().uuidString, message: msg))
            phase = .error(msg)
        }
        // A queued follow-up? Send it now while the model is still resident — never
        // unload/reload between back-to-back prompts. Only after a *completed* turn:
        // auto-starting the next goal after Stop (.aborted) would defeat the stop,
        // and a failed turn leaves the queue for the user to inspect/recall.
        // The working clock keeps running across the follow-up — it's the same session.
        if case .completed = outcome, !queued.isEmpty {
            autoNudges = 0   // an explicit user follow-up supersedes any auto-nudge
            let next = queued.removeFirst()
            append(.user(id: UUID().uuidString, text: next.text))
            persistTranscript()
            Task { await run(goal: next.text) }
            return
        }
        // Truly finished — stamp the elapsed working time into the transcript.
        postElapsedNote()
        // Snapshot the final transcript so the session survives an app relaunch.
        persistTranscript()
        // Next CLI job (own fresh session) once the current session fully drained.
        // Stop (.aborted) or a failure halts the CLI queue — auto-continuing would
        // defeat the stop / bury the failure under later runs.
        if case .completed = outcome, !cliQueue.isEmpty {
            runNextCLIJob()
            return
        }
        // The model ended the turn on a stated-but-unperformed action (narrated a
        // next step, or left an unparsed `<function=` tool-call fragment) with
        // nothing queued behind it. Re-enter the loop with a SILENT "Continue."
        // (no user bubble) instead of stranding the task idle. Bounded by
        // `autoNudges` — a model that only ever narrates can't loop forever, and the
        // counter resets on the first real tool call / file change.
        if case .completed = outcome, autoNudges < Self.maxAutoNudges, shouldAutoContinue() {
            autoNudges += 1
            log.info("agent auto-continue \(self.autoNudges, privacy: .public)/\(Self.maxAutoNudges, privacy: .public) — turn ended on an unperformed action")
            Task { await run(goal: "Continue.") }
            return
        }
        if !cliQueue.isEmpty {
            log.warning("agent CLI queue dropped (\(self.cliQueue.count, privacy: .public) pending) — turn did not complete")
            cliQueue.removeAll()
        }
        // Keep the model resident while the chat window is open: follow-up prompts
        // are the common case and a release here forces a full multi-GB reload per
        // prompt. Released when the window closes (`chatWindowDidClose`).
        // The MCP/hooks config file changed during the turn — respawn now that it's
        // drained so the next turn launches codex with the new servers/hooks.
        if agentConfigDirty { Task { await respawnHarnessForConfig() } }
        if ChatWindow.shared.isOpen { return }
        Task { await ModelResidencyCoordinator.shared.releaseAgent() }
    }

    /// The agent's MCP or hooks config file changed (external edit / import). codex reads
    /// both only when the app-server launches, so to apply them we respawn the harness:
    /// drop it now if idle (the next turn rebuilds `config.toml` and resumes the thread),
    /// or defer to turn end if a turn is in flight.
    /// ponytail: respawn-on-next-turn, not a live hot-swap — codex has no reload API.
    func applyAgentConfigChange() {
        switch phase {
        case .running, .awaitingApproval, .loadingModel:
            agentConfigDirty = true
        default:
            Task { await respawnHarnessForConfig() }
        }
    }

    private func respawnHarnessForConfig() async {
        // This runs from a detached Task, so a new turn may have started between the
        // dirty check at turn-end and now. Shutting the harness down mid-turn would kill
        // the live run — re-defer to the next turn-end instead.
        guard !isActive else { agentConfigDirty = true; return }
        agentConfigDirty = false
        guard harness != nil else { return }   // nothing resident → next spawn is fresh
        // Re-attach the current Codex thread on the new app-server so the conversation
        // survives the respawn. The agent model stays resident (acquireAgent is
        // coalesced), so this is a cheap harness restart, not a full reload.
        if let session { pendingResumeID = session.raw; self.session = nil }
        eventPump?.cancel()
        eventPump = nil
        // Detach state synchronously BEFORE the await: a `submit()` landing during the
        // shutdown suspension sees `harness == nil` and rebuilds a fresh one (resuming
        // via pendingResumeID), instead of starting a turn on the harness we're about to
        // kill. We shut down the captured local, not `self.harness`.
        let dying = harness
        harness = nil
        currentTurn = nil
        await dying?.shutdown()
    }

    /// Whether the just-finished turn ended on a stated-but-unperformed action and
    /// should be silently nudged to continue. Gated on the last *assistant* message
    /// (not a tool result), so a turn that ended on real output isn't retried.
    private func shouldAutoContinue() -> Bool {
        guard case .assistant(_, let text, false)? = items.last else { return false }
        return Self.signalsContinuation(text)
    }

    /// Pure detector (testable): does this assistant message promise a next step it
    /// did not perform? Conservative — only strong signals, so a genuine final answer
    /// ("Done. Created memlocal.md.") does not retrigger.
    nonisolated static func signalsContinuation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // Model emitted a tool call that didn't parse — the xml_function fragment is
        // still in user-visible content, so the server reported `stop`. Intended action.
        if t.contains("<function=") { return true }
        // Trailing colon: "…to understand the structure:" — about to show a command.
        if t.hasSuffix(":") { return true }
        // Last sentence opens with an intent lead-in ("Let me…", "I'll…", "Next, I…").
        let lastSentence = t.split(whereSeparator: { ".!?\n".contains($0) }).last.map(String.init) ?? t
        let lead = lastSentence.trimmingCharacters(in: .whitespaces).lowercased()
        let leadIns = ["let me ", "i'll ", "i will ", "now i", "now, i", "next, i", "next i",
                       "let's ", "lets ", "first, i", "first i", "going to ", "i'm going to ",
                       "i am going to ", "i need to ", "let me check", "let me look", "let me explore"]
        return leadIns.contains { lead.hasPrefix($0) }
    }

    /// Preload the agent model so the first prompt skips the residency swap (the
    /// user types the goal while the weights load). No phase change — `submit`
    /// coalesces onto the same in-flight load (`acquireAgent` is idempotent).
    func warmUp() {
        guard !isActive else { return }
        Task { _ = try? await ModelResidencyCoordinator.shared.acquireAgent { _, _ in } }
    }

    /// Window closed: release the agent model so inline completions resume. With a
    /// turn still in flight the release is deferred to `handleTurnCompleted` (which
    /// sees the window closed).
    func chatWindowDidClose() {
        guard !isActive else { return }
        Task { await ModelResidencyCoordinator.shared.releaseAgent() }
    }

    // MARK: - Transcript mutation

    private func append(_ item: AgentItem) {
        if let id = item.itemID { itemIndex[id] = items.count }
        items.append(item)
    }

    private func upsertText(_ itemID: String, text: String, reasoning: Bool) {
        if let idx = itemIndex[itemID], case .assistant(let id, let existing, let r) = items[idx], r == reasoning {
            items[idx] = .assistant(id: id, text: existing + text, reasoning: reasoning)
        } else {
            let item = AgentItem.assistant(id: itemID, text: text, reasoning: reasoning)
            itemIndex[itemID] = items.count
            items.append(item)
        }
    }

    private func upsertToolCall(_ call: ToolCall, output: String?) {
        if let idx = itemIndex[call.id], case .toolCall(_, _, _, _, let prevOut) = items[idx] {
            items[idx] = .toolCall(id: call.id, name: call.name, args: call.argumentsJSON,
                                   status: call.status, output: output ?? prevOut)
        } else {
            itemIndex[call.id] = items.count
            items.append(.toolCall(id: call.id, name: call.name, args: call.argumentsJSON,
                                   status: call.status, output: output ?? ""))
        }
    }

    private func appendToolOutput(_ id: String, chunk: ToolOutputChunk) {
        guard let idx = itemIndex[id], case .toolCall(let cid, let name, let args, let status, let out) = items[idx] else {
            // Output delta raced ahead of its item/started event — create a
            // placeholder so the leading chunks aren't silently dropped (the
            // completed event later replaces output with the authoritative whole).
            itemIndex[id] = items.count
            items.append(.toolCall(id: id, name: "", args: "", status: .running, output: chunk.text))
            return
        }
        items[idx] = .toolCall(id: cid, name: name, args: args, status: status, output: out + chunk.text)
    }

    private func upsertPlan(_ steps: [PlanStep]) {
        let item = AgentItem.plan(id: "plan", steps: steps)
        if let idx = itemIndex["plan"] { items[idx] = item } else {
            itemIndex["plan"] = items.count
            items.append(item)
        }
    }

    // MARK: - Resolution helpers

    /// `~/.config/prosper/codex` — app-private CODEX_HOME, never the user's `~/.codex`.
    static func codexHomeURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/prosper/codex", isDirectory: true)
    }

    /// Bundled binary at `Contents/Helpers/codex` (if a build staged one) → Homebrew/PATH
    /// (dev) → cached download → one-time download of the pinned release. Mirrors the
    /// model and bun on-demand delivery: a fresh install carries no codex, so users who
    /// never open the coding agent never pull the ~86 MB helper.
    static func resolveCodexExecutable() async throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codex")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        if let path = which("codex") { return URL(fileURLWithPath: path) }
        let cached = appSupportCodex()
        if FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        return try await downloadCodex(to: cached)
    }

    private static func appSupportCodex() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Prosper/codex", isDirectory: false)
    }

    /// One-time download of the pinned Codex release for this arch into Application
    /// Support. `nonisolated` so the SHA verify + tar extract + ad-hoc sign run off the
    /// main actor (seconds of work; would otherwise freeze the UI on first agent use).
    nonisolated private static func downloadCodex(to dest: URL) async throws -> URL {
        let triple = utsMachine() == "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin"
        let url = URL(string: "https://github.com/openai/codex/releases/download/\(codexVersion)/codex-\(triple).tar.gz")!
        let (tmpTgz, _) = try await URLSession.shared.download(from: url)

        // Verify against the pinned SHA-256 before extract/sign/exec — a compromised
        // release / MITM / DNS hijack would otherwise be code execution as the user.
        // Bump `codexSHA256` in lockstep with `codexVersion`.
        let hex = SHA256.hash(data: try Data(contentsOf: tmpTgz)).map { String(format: "%02x", $0) }.joined()
        guard hex == codexSHA256[triple] else {
            try? FileManager.default.removeItem(at: tmpTgz)
            throw HarnessError.spawnFailed("codex download checksum mismatch (\(hex))")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tmpTgz.path, "-C", work.path]
        tar.standardError = Pipe(); tar.standardOutput = Pipe()
        try tar.run(); tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw HarnessError.spawnFailed("codex tar extract failed") }

        // Tarball holds a single binary (codex or codex-<triple>).
        guard let bin = firstExecutable(in: work) else {
            throw HarnessError.spawnFailed("codex binary missing from release tarball")
        }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: bin, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        // A downloaded binary carries quarantine + no signature; strip + ad-hoc sign so it
        // execs without a Gatekeeper prompt or a hardened-runtime kill (same as the bun
        // helper). ponytail: ad-hoc only works because Prosper itself is ad-hoc signed,
        // not notarized — a notarized build with Library Validation would need the helper
        // signed with the same Developer ID (impossible at runtime) or pre-bundled.
        _ = run("/usr/bin/xattr", ["-d", "com.apple.quarantine", dest.path])
        _ = run("/usr/bin/codesign", ["--force", "--sign", "-", dest.path])
        return dest
    }

    /// First regular executable file under `dir` (the release tarball's single binary).
    nonisolated private static func firstExecutable(in dir: URL) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isExecutableKey]
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) {
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true, v?.isExecutable == true { return u }
            }
        }
        // Fallback: any file named codex* (some tars don't preserve the exec bit).
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.lastPathComponent.hasPrefix("codex") { return u }
        }
        return nil
    }

    nonisolated private static func utsMachine() -> String {
        var s = utsname(); uname(&s)
        return withUnsafeBytes(of: &s.machine) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Pinned Codex release. Bump alongside scripts/verify-codex-wire.sh + the SHA-256s.
    nonisolated static let codexVersion = "rust-v0.139.0"

    /// SHA-256 of each arch's `codex-<triple>.tar.gz` (GitHub release asset digest). Bump
    /// in lockstep with `codexVersion` — a stale hash fails the download closed.
    nonisolated private static let codexSHA256: [String: String] = [
        "aarch64-apple-darwin": "c28344255844d83a728c084c2d9e21e168b5d217f6049d3a9a36827903f16fdb",
        "x86_64-apple-darwin": "c8b52d7588977f6cd055112faa0f3e6b9ec764473bc1be8efa44f3c8f68d14bf",
    ]

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private static func describe(_ error: Error) -> String {
        if let h = error as? HarnessError {
            switch h {
            case .notStarted: return "Agent backend is not running."
            case .spawnFailed(let m): return "Could not start the agent: \(m)"
            case .protocolError(let m): return "Agent protocol error: \(m)"
            case .backendError(let m): return "Agent error: \(m)"
            case .timeout: return "Agent timed out."
            }
        }
        return String(describing: error)
    }
}

/// One rendered transcript entry. Value type; `AgentController` accumulates deltas by
/// replacing entries in place (tracked via `itemID`).
enum AgentItem: Identifiable, Equatable {
    case user(id: String, text: String)
    case assistant(id: String, text: String, reasoning: Bool)
    case toolCall(id: String, name: String, args: String, status: ToolCall.Status, output: String)
    case fileDiff(id: String, path: String, diff: String, change: FileDiff.Change)
    case plan(id: String, steps: [PlanStep])
    case error(id: String, message: String)
    /// A non-conversational footnote in the transcript (e.g. "Finished in 1m 23s").
    case note(id: String, text: String)

    var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _, _), .toolCall(let id, _, _, _, _),
             .fileDiff(let id, _, _, _), .plan(let id, _), .error(let id, _), .note(let id, _):
            return id
        }
    }
    /// The stable id used for delta upsert (same as `id`).
    var itemID: String? { id }
}
