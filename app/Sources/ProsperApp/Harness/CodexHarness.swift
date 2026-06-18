import Foundation
import os.log

/// `CodingHarness` backed by the OpenAI Codex `app-server` (JSON-RPC 2.0 over stdio).
///
/// Chosen as the first backend for: a single notarizable Rust binary (no runtime to
/// bundle), a native macOS Seatbelt sandbox for agent shell commands, and live
/// approval round-trips. It is pointed at Prosper's in-process `ProsperLLMServer`
/// (`wire_api = "responses"`) so all inference stays on the local MLX model.
///
/// **Protocol pinning:** the JSON-RPC method/field names live in `Wire` below and are
/// pinned to a specific Codex version. On a Codex bump, regenerate from
/// `codex app-server generate-json-schema` and diff against `Wire`. Unknown
/// notifications are ignored (forward-compatible), so a mismatch degrades to "missing
/// events", never a crash.
actor CodexHarness: CodingHarness {
    private let log = Logger(subsystem: "com.prosper.app", category: "CodexHarness")

    /// Path to the `codex` executable. Bundled at `Contents/Helpers/codex` in release;
    /// falls back to a `PATH` lookup for development.
    private let executableURL: URL
    /// App-private `CODEX_HOME` — never touches the user's `~/.codex`.
    private let codexHome: URL
    /// The local OpenAI-compatible endpoint Codex calls for inference.
    private let llmBaseURL: String
    private let llmToken: String

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// The single ordered stdout consumer (see `inboundStream`); cancelled on teardown.
    private var consumer: Task<Void, Never>?
    /// Set once by whichever teardown path runs first (`shutdown` or
    /// `handleTermination`) so the other becomes a no-op instead of re-tearing.
    private var terminated = false
    private var framer = JSONLineFramer()
    private var rpc = JSONRPC()

    /// Sendable box for JSON-RPC result dicts crossing the continuation boundary.
    private struct RPCResult: @unchecked Sendable { let dict: [String: Any] }

    /// In-flight client→server requests awaiting a response, keyed by JSON-RPC id.
    private var pending: [Int: CheckedContinuation<RPCResult, Error>] = [:]
    /// Maps an `ApprovalID` back to the server-request JSON-RPC id we must reply to,
    /// plus whether the request used the modern `item/*` method (whose decision enum
    /// is `accept`/`acceptForSession`/`decline`/`cancel`) or the legacy one
    /// (`approved`/`approved_for_session`/`denied`/`abort`).
    private var approvalReplies: [String: (rpcID: Any, modern: Bool)] = [:]

    private let eventStream: AsyncStream<HarnessEvent>
    private let eventContinuation: AsyncStream<HarnessEvent>.Continuation

    /// Raw stdout bytes, in arrival order, drained by a single consumer task into
    /// `ingest`. `readabilityHandler` fires on an arbitrary queue and splits frames
    /// across reads; hopping each read onto the actor with its own `Task` let the
    /// actor reorder them under reentrancy, corrupting the JSONL framer's buffer and
    /// silently dropping frames (e.g. a server→client approval request). Funneling
    /// through one ordered stream keeps the byte order the framer depends on.
    private nonisolated let inboundStream: AsyncStream<Data>
    private nonisolated let inboundContinuation: AsyncStream<Data>.Continuation

    nonisolated let capabilities = HarnessCapabilities(
        forking: true, liveApprovals: true, ptyExec: false, images: true
    )

    nonisolated var events: AsyncStream<HarnessEvent> { eventStream }

    init(executableURL: URL, codexHome: URL, llmBaseURL: String, llmToken: String) {
        self.executableURL = executableURL
        self.codexHome = codexHome
        self.llmBaseURL = llmBaseURL
        self.llmToken = llmToken
        var cont: AsyncStream<HarnessEvent>.Continuation!
        self.eventStream = AsyncStream { cont = $0 }
        self.eventContinuation = cont
        var inCont: AsyncStream<Data>.Continuation!
        self.inboundStream = AsyncStream(bufferingPolicy: .unbounded) { inCont = $0 }
        self.inboundContinuation = inCont
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard process == nil else { return }
        try writeConfig()

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        env["PROSPER_LLM_TOKEN"] = llmToken
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading

        // stdout = protocol frames. Push raw bytes into the inbound stream in arrival
        // order; a single consumer task (below) drains them into `ingest` serially.
        stdout.fileHandleForReading.readabilityHandler = { [inboundContinuation] handle in
            let data = handle.availableData
            if !data.isEmpty { inboundContinuation.yield(data) }
        }
        // The one ordered reader: `await ingest` per chunk, sequentially, so frames
        // are never reordered relative to the bytes the framer buffers.
        consumer = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.inboundStream { await self.ingest(chunk) }
        }
        // stderr = logs only.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { await self.logStderr(s) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            Task { await self.handleTermination(code: p.terminationStatus) }
        }

        do {
            try proc.run()
        } catch {
            throw HarnessError.spawnFailed(String(describing: error))
        }
        self.process = proc

        // Handshake: initialize → wait for result → initialized notification. On any
        // failure tear the half-spawned process down before rethrowing — otherwise the
        // codex subprocess leaks (running, unreaped) and `process != nil` wedges retries.
        do {
            let initParams: [String: Any] = [
                "clientInfo": ["name": "prosper", "title": "Prosper", "version": Self.appVersion],
            ]
            _ = try await sendRequest(method: Wire.initialize, params: initParams)
            try writeLine(JSONRPC.notification(method: Wire.initialized, params: [:]))
        } catch {
            await shutdown()
            throw error
        }
    }

    func shutdown() async {
        guard !terminated else { return }
        terminated = true
        for (_, cont) in pending { cont.resume(throwing: HarnessError.notStarted) }
        pending.removeAll()
        let proc = process
        process = nil
        proc?.terminationHandler = nil   // teardown owns this exit; no second entry
        proc?.terminate()
        cleanupIO()
        // Reap off the actor so a slow exit can't block it; SIGKILL the straggler.
        if let proc {
            Task.detached {
                let deadline = Date().addingTimeInterval(3)
                while proc.isRunning, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                proc.waitUntilExit()
            }
        }
    }

    /// Shared by `shutdown` and `handleTermination`: detach pipe handlers (they
    /// retain their closures and keep the dispatch sources live), close the
    /// handles, and stop the inbound consumer. Idempotent.
    private func cleanupIO() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdinHandle?.writeabilityHandler = nil
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        try? stdinHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
        stdinHandle = nil
        consumer?.cancel()
        consumer = nil
        approvalReplies.removeAll()   // codex is gone; no reply can land
        inboundContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Sessions / turns

    func newSession(_ opts: SessionOptions) async throws -> SessionID {
        let params: [String: Any] = [
            "cwd": opts.cwd,
            "model": opts.model,
            "approvalPolicy": opts.approvalPolicy.rawValue,
            "sandboxPolicy": Self.sandboxJSON(opts.sandbox, cwd: opts.cwd),
        ]
        let result = try await sendRequest(method: Wire.threadStart, params: params)
        guard let id = Self.threadID(from: result) else {
            throw HarnessError.protocolError("thread/start returned no thread id")
        }
        let session = SessionID(raw: id)
        eventContinuation.yield(.sessionStarted(session))
        return session
    }

    func resumeSession(_ id: SessionID) async throws -> SessionID {
        let result = try await sendRequest(method: Wire.threadResume, params: ["threadId": id.raw])
        let resumed = Self.threadID(from: result) ?? id.raw
        return SessionID(raw: resumed)
    }

    func forkSession(_ id: SessionID) async throws -> SessionID {
        let result = try await sendRequest(method: Wire.threadFork, params: ["threadId": id.raw])
        guard let forked = Self.threadID(from: result) else {
            throw HarnessError.protocolError("thread/fork returned no thread id")
        }
        return SessionID(raw: forked)
    }

    @discardableResult
    func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID {
        let params: [String: Any] = [
            "threadId": session.raw,
            "input": input.map(Self.inputJSON),
        ]
        let result = try await sendRequest(method: Wire.turnStart, params: params)
        let turnID = TurnID(raw: (result["turnId"] as? String) ?? UUID().uuidString)
        eventContinuation.yield(.turnStarted(turnID))
        return turnID
    }

    func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws {
        try writeLine(JSONRPC.notification(method: Wire.turnSteer, params: [
            "threadId": session.raw, "turnId": turn.raw, "input": input.map(Self.inputJSON),
        ]))
    }

    func abort(session: SessionID, turn: TurnID?) async throws {
        var params: [String: Any] = ["threadId": session.raw]
        if let turn { params["turnId"] = turn.raw }
        try writeLine(JSONRPC.notification(method: Wire.turnInterrupt, params: params))
    }

    func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws {
        guard let reply = approvalReplies[id.raw] else {
            throw HarnessError.protocolError("unknown approval id \(id.raw)")
        }
        try writeLine(JSONRPC.response(
            id: reply.rpcID,
            result: ["decision": Self.decisionString(decision, modern: reply.modern)]))
        // Only after a successful write — a failed write keeps the mapping so the
        // decision can be retried instead of orphaning the codex-side request.
        approvalReplies.removeValue(forKey: id.raw)
    }

    // MARK: - I/O

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process != nil, !terminated else { throw HarnessError.notStarted }
        let (id, line) = rpc.request(method: method, params: params)
        let result: RPCResult = try await withCheckedThrowingContinuation { cont in
            // shutdown/handleTermination drain `pending` synchronously on the actor; if
            // either ran before this closure, our continuation would be stored after the
            // drain and never resumed (hang). Re-check under actor isolation here.
            guard !terminated else { cont.resume(throwing: HarnessError.notStarted); return }
            pending[id] = cont
            do { try writeLine(line) }
            catch { pending[id] = nil; cont.resume(throwing: error) }
        }
        return result.dict
    }

    private func writeLine(_ data: Data) throws {
        guard let stdinHandle else { throw HarnessError.notStarted }
        do { try stdinHandle.write(contentsOf: data) }
        catch { throw HarnessError.backendError("stdin write failed: \(error)") }
    }

    private func ingest(_ data: Data) {
        guard !terminated else { return }   // late stdout after teardown — drop it
        for obj in framer.append(data) {
            guard let frame = JSONRPCFrame(obj) else { continue }
            switch frame {
            case .response(let id, let result, let error):
                guard let cont = pending.removeValue(forKey: id) else { continue }
                if let error {
                    cont.resume(throwing: HarnessError.backendError(
                        (error["message"] as? String) ?? String(describing: error)))
                } else {
                    cont.resume(returning: RPCResult(dict: result ?? [:]))
                }
            case .serverRequest(let id, let method, let params):
                handleServerRequest(id: id, method: method, params: params)
            case .notification(let method, let params):
                // A turn ending orphans any approval it left unanswered (codex won't
                // re-request); drop the mappings so they can't accumulate across turns.
                if method == Wire.turnCompleted { approvalReplies.removeAll() }
                for event in Self.mapNotification(method: method, params: params) {
                    eventContinuation.yield(event)
                }
            }
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        guard let kind = Wire.approvalKind(for: method) else {
            // Unknown server request — decline politely so Codex isn't left hanging.
            let fallback = method.hasPrefix("item/") ? "decline" : "denied"
            try? writeLine(JSONRPC.response(id: id, result: ["decision": fallback]))
            return
        }
        let approvalID = ApprovalID(raw: UUID().uuidString)
        approvalReplies[approvalID.raw] = (rpcID: id, modern: method.hasPrefix("item/"))
        let session = SessionID(raw: (params["threadId"] as? String) ?? "")
        let request = ApprovalRequest(
            id: approvalID, kind: kind, session: session,
            summary: Self.approvalSummary(kind: kind, params: params),
            detail: Self.approvalDetail(kind: kind, params: params)
        )
        eventContinuation.yield(.approvalRequest(request))
    }

    private func logStderr(_ s: String) {
        log.debug("[codex] \(s, privacy: .public)")
    }

    private func handleTermination(code: Int32) {
        guard !terminated else { return }
        terminated = true
        process = nil
        for (_, cont) in pending { cont.resume(throwing: HarnessError.backendError("codex exited (\(code))")) }
        pending.removeAll()
        if code != 0 {
            eventContinuation.yield(.error(.backendError("codex app-server exited with code \(code)")))
        }
        cleanupIO()
    }

    // MARK: - Config

    /// Developer-level instruction (codex `developer_instructions`, higher precedence
    /// than AGENTS.md, additive to the base prompt) that fights the local-model
    /// "narrate-then-stop" failure: small models routinely end a turn announcing an
    /// action ("let me check…") without emitting the tool call to do it, and codex
    /// correctly reports the turn complete. Industry line-1 mitigation (Copilot's
    /// "Autonomous Mode" instruction). TOML literal string (`'''`) — no escaping, no
    /// interpolation; keep the text free of `'''`.
    private static let baseInstructions = """
    Act, don't announce. When you state you are about to do something (e.g. "let me check", "I'll run", "next I will"), you MUST perform that action with a tool call in the same turn. Never end your turn on a stated-but-unperformed action — either call the tool now, or give your final answer. Execute the steps of a plan sequentially without pausing for the user between them, unless a command requires approval or the step is destructive or irreversible.
    """

    /// Base instructions plus the selected persona's prompt (F3b), wrapped as a TOML
    /// literal string (`'''`). Persona text is stripped of `'''` so it can't break out
    /// of the literal. Read at config-write time, so a persona switch needs a respawn.
    private static func developerInstructions() -> String {
        var text = baseInstructions
        let persona = AgentPersonaStore.prompt(for: Preferences.agentPersona)
            .replacingOccurrences(of: "'''", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty { text += "\n\n" + persona }
        return "'''\n" + text + "\n'''"
    }

    private func writeConfig() throws {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        // MCP servers are appended as `[mcp_servers.*]` blocks. codex reads them at
        // app-server launch only, so they apply to the next run, not a live session.
        let mcp = MCPServer.tomlBlocks(for: Preferences.mcpServers)
        // Lifecycle hooks append as `[[hooks.<Event>]]` blocks — same launch-only read.
        let hooks = HookRule.tomlBlocks(for: Preferences.hooks)
        // Bun plugin bridge: one `nc -U <socket>` hook per event a loaded opencode plugin
        // handles (empty when the host isn't running → no blocks, no per-tool overhead).
        let bridge = HookRule.tomlBlocks(for: BunHarness.neededEvents().map {
            HookRule(event: $0, command: BunHarness.bridgeCommand())
        })
        // Quote interpolated values (model id is registry-controlled today, but
        // TOML injection via a future settable path is a one-character mistake).
        let config = """
        model = \(MCPServer.q(Preferences.agentModel))
        model_provider = "prosper"
        developer_instructions = \(Self.developerInstructions())

        [model_providers.prosper]
        name = "Prosper local MLX"
        base_url = \(MCPServer.q(llmBaseURL))
        wire_api = "responses"
        env_key = "PROSPER_LLM_TOKEN"
        """ + mcp + hooks + bridge
        try config.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    // MARK: - Static mapping helpers

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func threadID(from result: [String: Any]) -> String? {
        (result["threadId"] as? String)
            ?? (result["thread"] as? [String: Any])?["id"] as? String
            ?? (result["id"] as? String)
    }

    private static func inputJSON(_ input: PromptInput) -> [String: Any] {
        switch input {
        case .text(let t): return ["type": "text", "text": t]
        case .image(let path): return ["type": "image", "path": path]
        }
    }

    private static func sandboxJSON(_ policy: SandboxPolicy, cwd: String) -> [String: Any] {
        switch policy {
        case .readOnly:
            return ["type": "readOnly"]
        case .workspaceWrite(let net):
            // cwd is always writable; extra roots come from the Permissions allowlist (F4).
            let roots = [cwd] + Preferences.agentWritableRoots
            return ["type": "workspaceWrite", "writableRoots": roots, "networkAccess": net]
        case .dangerFullAccess:
            return ["type": "dangerFullAccess"]
        }
    }

    /// Decision wire string per protocol generation (verified against
    /// `codex app-server generate-json-schema`): modern `item/*/requestApproval`
    /// responses use `CommandExecutionApprovalDecision`, legacy
    /// `execCommandApproval`/`applyPatchApproval` use `ReviewDecision`.
    private static func decisionString(_ d: ApprovalDecision, modern: Bool) -> String {
        switch d {
        case .accept: return modern ? "accept" : "approved"
        case .acceptForSession: return modern ? "acceptForSession" : "approved_for_session"
        case .decline: return modern ? "decline" : "denied"
        case .cancel: return modern ? "cancel" : "abort"
        case .acceptWithAmendment: return modern ? "accept" : "approved"   // amendment payload handled separately if supported
        }
    }

    private static func approvalSummary(kind: ApprovalRequest.Kind, params: [String: Any]) -> String {
        switch kind {
        case .command:
            if let cmd = params["command"] as? [String] { return cmd.joined(separator: " ") }
            return (params["command"] as? String) ?? "Run a command"
        case .fileChange:
            return "Apply changes to \((params["path"] as? String) ?? "files")"
        case .permission:
            return (params["reason"] as? String) ?? "Grant a permission"
        }
    }

    private static func approvalDetail(kind: ApprovalRequest.Kind, params: [String: Any]) -> String? {
        switch kind {
        case .command: return params["cwd"] as? String
        case .fileChange: return (params["changes"] as? [String: Any]).flatMap { try? String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8) }
        case .permission: return params["detail"] as? String
        }
    }

    /// Notification → zero or more `HarnessEvent`s. Empty for notifications we don't
    /// surface; a single `item/completed` carrying a multi-file patch fans out to one
    /// `.fileChange` per changed file, hence `[HarnessEvent]`.
    ///
    /// Pinned to Codex app-server protocol v1 (verified against the bundled binary's
    /// `generate-json-schema --out` output). Command/file execution arrive through the
    /// generic item lifecycle envelope (`item/started` / `item/completed`, discriminated
    /// by `item.type`), not per-type methods.
    static func mapNotification(method: String, params: [String: Any]) -> [HarnessEvent] {
        let turn = TurnID(raw: (params["turnId"] as? String) ?? "")
        switch method {
        case Wire.turnStarted:
            return [.turnStarted(TurnID(raw: (params["turnId"] as? String) ?? ""))]

        case Wire.agentMessageDelta:
            let itemID = (params["itemId"] as? String) ?? (params["id"] as? String) ?? ""
            return [.textDelta(turn: turn, itemID: itemID, text: (params["delta"] as? String) ?? "")]

        case Wire.reasoningDelta, Wire.reasoningSummaryDelta:
            let itemID = (params["itemId"] as? String) ?? (params["id"] as? String) ?? ""
            return [.reasoningDelta(turn: turn, itemID: itemID, text: (params["delta"] as? String) ?? "")]

        case Wire.commandOutputDelta:
            let itemID = (params["itemId"] as? String) ?? (params["id"] as? String) ?? ""
            let stream: ToolOutputChunk.Stream = (params["stream"] as? String) == "stderr" ? .stderr : .stdout
            return [.toolCallOutput(id: itemID, chunk: ToolOutputChunk(stream: stream, text: (params["delta"] as? String) ?? ""))]

        case Wire.itemStarted:
            guard let item = params["item"] as? [String: Any] else { return [] }
            return itemStartedEvents(item)

        case Wire.itemCompleted:
            guard let item = params["item"] as? [String: Any] else { return [] }
            return itemCompletedEvents(turn: turn, item)

        case Wire.planUpdated:
            let steps = (params["plan"] as? [[String: Any]] ?? []).map {
                PlanStep(title: ($0["step"] as? String) ?? ($0["title"] as? String) ?? "",
                         state: planState($0["status"] as? String))
            }
            return [.planUpdated(turn: turn, steps)]

        case Wire.tokenUsage:
            // params.tokenUsage = { last, total: TokenUsageBreakdown, modelContextWindow }
            let breakdown = (params["tokenUsage"] as? [String: Any])?["total"] as? [String: Any] ?? [:]
            return [.usage(TokenUsage(
                inputTokens: (breakdown["inputTokens"] as? Int) ?? 0,
                outputTokens: (breakdown["outputTokens"] as? Int) ?? 0))]

        case Wire.turnCompleted:
            // params.turn = Turn { id, status, error? }
            let t = params["turn"] as? [String: Any] ?? [:]
            let turnID = TurnID(raw: (t["id"] as? String) ?? turn.raw)
            return [.turnCompleted(turn: turnID, turnOutcome(t["status"] as? String, turn: t))]

        default:
            return []
        }
    }

    /// `item/started` → events. Only a command execution surfaces a start card; message,
    /// reasoning, plan, and file-change items render from deltas / on completion.
    private static func itemStartedEvents(_ item: [String: Any]) -> [HarnessEvent] {
        let id = (item["id"] as? String) ?? ""
        switch item["type"] as? String {
        case "commandExecution":
            return [.toolCallStarted(ToolCall(
                id: id, name: "shell",
                argumentsJSON: jsonString(item["command"] ?? "")))]
        default:
            return []
        }
    }

    /// `item/completed` → events, discriminated by `item.type`. A file-change item
    /// fans out to one `.fileChange` per entry in `item.changes`.
    private static func itemCompletedEvents(turn: TurnID, _ item: [String: Any]) -> [HarnessEvent] {
        let id = (item["id"] as? String) ?? ""
        switch item["type"] as? String {
        case "commandExecution":
            let exit = item["exitCode"] as? Int
            let dur = item["durationMs"] as? Int
            let agg = (item["aggregatedOutput"] as? String) ?? ""
            let status = commandStatus(item["status"] as? String, exitCode: exit)
            return [.toolCallCompleted(ToolCall(
                id: id, name: "shell",
                argumentsJSON: jsonString(item["command"] ?? ""),
                status: status,
                output: commandSummary(output: agg, exitCode: exit, durationMs: dur, status: status)))]
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            return changes.map { change in
                .fileChange(turn: turn, FileDiff(
                    path: (change["path"] as? String) ?? "",
                    unifiedDiff: (change["diff"] as? String) ?? "",
                    change: fileChangeKind((change["kind"] as? [String: Any])?["type"] as? String)))
            }
        default:
            return []
        }
    }

    private static func fileChangeKind(_ s: String?) -> FileDiff.Change {
        switch s { case "add": return .add; case "delete": return .delete; default: return .modify }
    }
    private static func planState(_ s: String?) -> PlanStep.State {
        switch s { case "completed", "done": return .done; case "in_progress", "inProgress": return .inProgress; default: return .pending }
    }
    /// Build the tool card's body: the command's combined stdout/stderr followed by a
    /// one-line footer that always reports how it ended (exit code + duration), so a
    /// failed-but-silent command still shows *why* instead of a bare red X.
    private static func commandSummary(output: String, exitCode: Int?, durationMs: Int?,
                                       status: ToolCall.Status) -> String {
        var parts: [String] = []
        let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        var footer: String
        if let exitCode {
            footer = exitCode == 0 ? "exit 0" : "exit \(exitCode)"
        } else {
            footer = status == .failed ? "failed (no exit code — likely blocked or not started)" : "done"
        }
        if let durationMs { footer += " · \(formatDuration(durationMs))" }
        parts.append("— \(footer)")
        return parts.joined(separator: "\n")
    }

    private static func formatDuration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }

    /// CommandExecutionStatus { inProgress, completed, failed, declined } + exit code.
    private static func commandStatus(_ s: String?, exitCode: Int?) -> ToolCall.Status {
        switch s {
        case "inProgress": return .running
        case "failed", "declined": return .failed
        case "completed": return (exitCode ?? 0) == 0 ? .succeeded : .failed
        default: return (exitCode ?? 0) == 0 ? .succeeded : .failed
        }
    }
    /// TurnStatus { completed, interrupted, failed, inProgress }; error.message on failure.
    private static func turnOutcome(_ s: String?, turn: [String: Any]) -> TurnOutcome {
        switch s {
        case "interrupted": return .aborted
        case "failed":
            let msg = (turn["error"] as? [String: Any])?["message"] as? String
            return .failed(msg ?? "turn failed")
        default: return .completed
        }
    }
    private static func jsonString(_ any: Any) -> String {
        if let s = any as? String { return s }
        return (try? JSONSerialization.data(withJSONObject: any)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(any)"
    }
}

/// Codex app-server JSON-RPC method names + approval classification, centralized for
/// version pinning. Bump alongside the bundled Codex binary; regenerate from
/// `codex app-server generate-json-schema` and diff.
private enum Wire {
    static let initialize = "initialize"
    static let initialized = "initialized"

    static let threadStart = "thread/start"
    static let threadResume = "thread/resume"
    static let threadFork = "thread/fork"

    static let turnStart = "turn/start"
    static let turnSteer = "turn/steer"
    static let turnInterrupt = "turn/interrupt"

    // Notifications (ServerNotification methods, protocol v1)
    static let turnStarted = "turn/started"
    static let turnCompleted = "turn/completed"
    static let agentMessageDelta = "item/agentMessage/delta"
    static let reasoningDelta = "item/reasoning/textDelta"
    static let reasoningSummaryDelta = "item/reasoning/summaryTextDelta"
    static let commandOutputDelta = "item/commandExecution/outputDelta"
    // Command + file execution arrive via the generic item lifecycle envelope,
    // discriminated by `item.type` (commandExecution / fileChange).
    static let itemStarted = "item/started"
    static let itemCompleted = "item/completed"
    static let planUpdated = "turn/plan/updated"
    static let tokenUsage = "thread/tokenUsage/updated"

    /// Server→client approval requests. Maps a request method to its UI kind.
    static func approvalKind(for method: String) -> ApprovalRequest.Kind? {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            return .command
        case "item/fileChange/requestApproval", "applyPatchApproval":
            return .fileChange
        case "item/permissions/requestApproval":
            return .permission
        default:
            return nil
        }
    }
}
