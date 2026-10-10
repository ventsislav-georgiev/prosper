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
    /// the request method (each has its own response shape, see `approvalResult`) and,
    /// for a permissions request, the requested profile a grant echoes back.
    private var approvalReplies: [String: (rpcID: Any, method: String, requested: [String: Any])] = [:]
    /// `fileChange` items from `item/started`, by item id: `item/fileChange/requestApproval`
    /// carries only the `itemId`, so the approval's diff comes from here. Cleared per turn.
    private var fileChanges: [String: [[String: Any]]] = [:]
    /// `turn/start.sandboxPolicy` per thread id. Thread start/resume only take the mode
    /// string, so the writable roots and the network toggle ride on every turn.
    private var sandboxPolicies: [String: [String: Any]] = [:]

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
            let signaled = p.terminationReason == .uncaughtSignal
            Task { await self.handleTermination(code: p.terminationStatus, signaled: signaled) }
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
            let info = try await sendRequest(method: Wire.initialize, params: initParams)
            // `userAgent` = "<originator>/<codex version> (…)": the version actually serving the wire.
            log.notice("codex \(self.executableURL.path, privacy: .public): \(info["userAgent"] as? String ?? "no userAgent", privacy: .public)")
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
        fileChanges.removeAll()
        inboundContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Sessions / turns

    func newSession(_ opts: SessionOptions) async throws -> SessionID {
        let params: [String: Any] = [
            "cwd": opts.cwd,
            "model": opts.model,
            "approvalPolicy": opts.approvalPolicy.rawValue,
            "sandbox": Self.sandboxMode(opts.sandbox),
            "config": Self.threadConfig,
        ]
        let result = try await sendRequest(method: Wire.threadStart, params: params)
        guard let id = Self.threadID(from: result) else {
            throw HarnessError.protocolError("thread/start returned no thread id")
        }
        sandboxPolicies[id] = Self.sandboxJSON(opts.sandbox, cwd: opts.cwd)
        let session = SessionID(raw: id)
        eventContinuation.yield(.sessionStarted(session))
        return session
    }

    func resumeSession(_ id: SessionID, options opts: SessionOptions) async throws -> SessionID {
        let result = try await sendRequest(method: Wire.threadResume, params: [
            "threadId": id.raw,
            "approvalPolicy": opts.approvalPolicy.rawValue,
            "sandbox": Self.sandboxMode(opts.sandbox),
            "config": Self.threadConfig,
        ])
        let resumed = Self.threadID(from: result) ?? id.raw
        sandboxPolicies[resumed] = Self.sandboxJSON(opts.sandbox, cwd: opts.cwd)
        return SessionID(raw: resumed)
    }

    func forkSession(_ id: SessionID) async throws -> SessionID {
        let result = try await sendRequest(method: Wire.threadFork, params: [
            "threadId": id.raw, "config": Self.threadConfig,
        ])
        guard let forked = Self.threadID(from: result) else {
            throw HarnessError.protocolError("thread/fork returned no thread id")
        }
        sandboxPolicies[forked] = sandboxPolicies[id.raw]
        return SessionID(raw: forked)
    }

    @discardableResult
    func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID {
        var params: [String: Any] = [
            "threadId": session.raw,
            "input": input.map(Self.inputJSON),
        ]
        params["sandboxPolicy"] = sandboxPolicies[session.raw]
        let result = try await sendRequest(method: Wire.turnStart, params: params)
        // TurnStartResponse = { turn: Turn { id, items, status } }.
        guard let id = (result["turn"] as? [String: Any])?["id"] as? String else {
            throw HarnessError.protocolError("turn/start returned no turn id")
        }
        let turnID = TurnID(raw: id)
        eventContinuation.yield(.turnStarted(turnID))
        return turnID
    }

    /// `turn/steer` and `turn/interrupt` are JSON-RPC requests: codex parses an id-less
    /// message as a ClientNotification (only `initialized`) and drops it.
    func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws {
        _ = try await sendRequest(method: Wire.turnSteer, params: [
            "threadId": session.raw, "expectedTurnId": turn.raw, "input": input.map(Self.inputJSON),
        ])
    }

    /// Codex replies `{}` and then ends the turn with `turn/completed{status: interrupted}`.
    /// `turnId` is required, so with no turn there is nothing to interrupt.
    func abort(session: SessionID, turn: TurnID?) async throws {
        try await abort(session: session, turn: turn, timeout: 5)
    }

    /// Bounded so Stop can't hang on a wedged codex: throws `HarnessError.timeout` when
    /// the interrupt isn't answered within `timeout` seconds.
    func abort(session: SessionID, turn: TurnID?, timeout: TimeInterval) async throws {
        guard let turn else { return }
        _ = try await sendRequest(method: Wire.turnInterrupt, params: [
            "threadId": session.raw, "turnId": turn.raw,
        ], timeout: timeout)
    }

    func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws {
        guard let reply = approvalReplies[id.raw] else {
            throw HarnessError.protocolError("unknown approval id \(id.raw)")
        }
        try writeLine(JSONRPC.response(
            id: reply.rpcID,
            result: Self.approvalResult(method: reply.method, requested: reply.requested, decision: decision)))
        // Only after a successful write — a failed write keeps the mapping so the
        // decision can be retried instead of orphaning the codex-side request.
        approvalReplies.removeValue(forKey: id.raw)
    }

    // MARK: - I/O

    /// `timeout` (seconds) fails the request with `HarnessError.timeout`; a late reply
    /// then finds no pending entry and is dropped. nil waits for the reply.
    private func sendRequest(method: String, params: [String: Any],
                             timeout: TimeInterval? = nil) async throws -> [String: Any] {
        guard process != nil, !terminated else { throw HarnessError.notStarted }
        let (id, line) = rpc.request(method: method, params: params)
        let result: RPCResult = try await withCheckedThrowingContinuation { cont in
            // shutdown/handleTermination drain `pending` synchronously on the actor; if
            // either ran before this closure, our continuation would be stored after the
            // drain and never resumed (hang). Re-check under actor isolation here.
            guard !terminated else { cont.resume(throwing: HarnessError.notStarted); return }
            pending[id] = cont
            do { try writeLine(line) }
            catch { pending[id] = nil; cont.resume(throwing: error); return }
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.expireRequest(id)
                }
            }
        }
        return result.dict
    }

    private func expireRequest(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: HarnessError.timeout)
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
                // fileChanges is unbounded within a turn and cleared by ANY thread's
                // turn end (accepted: one turn's patches are small, approvals are rare).
                if method == Wire.turnCompleted { approvalReplies.removeAll(); fileChanges.removeAll() }
                if method == Wire.itemStarted, let item = params["item"] as? [String: Any],
                   item["type"] as? String == "fileChange", let id = item["id"] as? String {
                    fileChanges[id] = item["changes"] as? [[String: Any]] ?? []
                }
                for event in Self.mapNotification(method: method, params: params) {
                    eventContinuation.yield(event)
                }
            }
        }
    }

    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        guard let kind = Wire.approvalKind(for: method) else {
            // A request we don't serve (user input, MCP elicitation, dynamic tool call,
            // auth refresh, …): each has its own response type, so a made-up result is
            // undecodable. Answer with JSON-RPC "method not found" so codex isn't left hanging.
            try? writeLine(JSONRPC.errorResponse(
                id: id, code: -32601, message: "\(method) is not supported by this client"))
            return
        }
        let approvalID = ApprovalID(raw: UUID().uuidString)
        approvalReplies[approvalID.raw] = (rpcID: id, method: method,
                                           requested: params["permissions"] as? [String: Any] ?? [:])
        let session = SessionID(raw: (params["threadId"] as? String) ?? "")
        // Modern requests carry only `itemId` (diff comes from the item); legacy
        // `applyPatchApproval` carries `fileChanges` keyed by path: show its paths.
        let changes: [[String: Any]] = method == Wire.fileChangeApproval
            ? (params["itemId"] as? String).flatMap { fileChanges[$0] } ?? []
            : method == Wire.legacyPatchApproval
            ? ((params["fileChanges"] as? [String: Any])?.keys.sorted() ?? []).map { ["path": $0] }
            : []
        let request = ApprovalRequest(
            id: approvalID, kind: kind, session: session,
            summary: Self.approvalSummary(kind: kind, params: params, changes: changes),
            detail: Self.approvalDetail(kind: kind, params: params, changes: changes)
        )
        eventContinuation.yield(.approvalRequest(request))
    }

    private func logStderr(_ s: String) {
        log.debug("[codex] \(s, privacy: .public)")
    }

    /// An exit we didn't ask for (`shutdown` clears the handler first), so it is an
    /// error whatever the code: a clean exit mid-turn sends no `turn/completed` either.
    /// In-flight requests and the event stream carry the same error, which lets the
    /// controller show it once; the stream then finishes so it can drop this harness.
    private func handleTermination(code: Int32, signaled: Bool) {
        guard !terminated else { return }
        terminated = true
        process = nil
        let error = HarnessError.backendError(signaled
            ? "codex app-server was killed by signal \(code)"
            : "codex app-server exited with code \(code)")
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        eventContinuation.yield(.error(error))
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
        # Local generation: a dropped or stalled stream fails the turn in seconds
        # instead of codex's 5 reconnects / 4 request retries / 300 s idle wait.
        stream_max_retries = 0
        request_max_retries = 1
        stream_idle_timeout_ms = 120000
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

    static func inputJSON(_ input: PromptInput) -> [String: Any] {
        switch input {
        case .text(let t): return ["type": "text", "text": t]
        case .image(let path): return ["type": "localImage", "path": path] // codex `image` takes url/fileId; local files are `localImage`
        }
    }

    /// Request overrides for thread start/resume/fork. codex registers a non-managed hook
    /// only if `hooks.state` holds its `trusted_hash` or the session bypasses hook trust;
    /// Prosper writes no trust state, so without this every hook (user hooks and the Bun
    /// plugin bridge) is silently skipped. The hooks are authored in Prosper's Settings,
    /// which makes Prosper the vetting layer.
    /// Invariant: this trusts every hook in the ENABLED config layers. A hostile repo's `.codex`
    /// hooks still do not load only because codex 0.161.0 disables an untrusted project layer
    /// (loader_mod.rs:1090-1135) and hook discovery skips disabled layers, so Prosper must never
    /// mark a project layer trusted.
    private static var threadConfig: [String: Any] { ["bypass_hook_trust": true] }

    /// `thread/start|resume.sandbox` is a `SandboxMode` string; the full policy (writable
    /// roots, network) goes on `turn/start.sandboxPolicy` via `sandboxJSON`.
    private static func sandboxMode(_ policy: SandboxPolicy) -> String {
        switch policy {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .dangerFullAccess: return "danger-full-access"
        }
    }

    /// `turn/start.sandboxPolicy` (codex `SandboxPolicy`, camelCase `type` tags).
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

    /// The approval reply's `result`, per request method (codex 0.162 schema):
    /// - `item/permissions/requestApproval` → `PermissionsRequestApprovalResponse
    ///   {permissions: GrantedPermissionProfile, scope: "turn" | "session"}` — a grant echoes
    ///   the requested profile, a refusal grants nothing (`{}`); there is no decision field.
    /// - `item/commandExecution/requestApproval` → `{decision}`; the amendment is the object
    ///   variant `{"acceptWithExecpolicyAmendment": {"execpolicy_amendment": [argv prefix]}}`.
    /// - `item/fileChange/requestApproval` / `applyPatchApproval` → `{decision}`, no amendment.
    /// - legacy `execCommandApproval` → `{decision: ReviewDecision}`, amendment
    ///   `{"approved_execpolicy_amendment": {"proposed_execpolicy_amendment": [...]}}`.
    private static func approvalResult(method: String, requested: [String: Any],
                                       decision: ApprovalDecision) -> [String: Any] {
        if method == Wire.permissionsApproval {
            switch decision {
            case .accept, .acceptWithAmendment: return ["permissions": requested, "scope": "turn"]
            case .acceptForSession: return ["permissions": requested, "scope": "session"]
            case .decline, .cancel: return ["permissions": [String: Any](), "scope": "turn"]
            }
        }
        let modern = method.hasPrefix("item/")
        // An empty prefix would amend nothing useful: fall through to a plain accept.
        if case .acceptWithAmendment(let prefix) = decision, !prefix.isEmpty,
           method == Wire.commandApproval || method == Wire.legacyCommandApproval {
            return ["decision": modern
                ? ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": prefix]]
                : ["approved_execpolicy_amendment": ["proposed_execpolicy_amendment": prefix]]]
        }
        return ["decision": decisionString(decision, modern: modern)]
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
        case .acceptWithAmendment: return modern ? "accept" : "approved"   // no amendment variant (file change) — see approvalResult
        }
    }

    /// `changes`: the `FileUpdateChange`s (`{path, kind, diff}`) of the approval's
    /// `fileChange` item; empty for other kinds.
    private static func approvalSummary(kind: ApprovalRequest.Kind, params: [String: Any],
                                        changes: [[String: Any]]) -> String {
        switch kind {
        case .command:
            if let cmd = params["command"] as? [String] { return cmd.joined(separator: " ") }
            return (params["command"] as? String) ?? "Run a command"
        case .fileChange:
            let paths = changes.compactMap { $0["path"] as? String }.map(oneLine)
            return "Apply changes to \(paths.isEmpty ? "files" : paths.joined(separator: ", "))"
        case .permission:
            return (params["reason"] as? String) ?? "Grant a permission"
        }
    }

    private static func approvalDetail(kind: ApprovalRequest.Kind, params: [String: Any],
                                       changes: [[String: Any]]) -> String? {
        switch kind {
        case .command: return params["cwd"] as? String
        case .fileChange:
            let diffs = changes.map { "\(oneLine(($0["path"] as? String) ?? ""))\n\(($0["diff"] as? String) ?? "")" }
            return diffs.isEmpty ? nil : diffs.joined(separator: "\n")
        case .permission:
            // codex sends no `detail`; "Always" grants this whole `RequestPermissionProfile`,
            // so show its roots (legacy read/write lists plus `entries` by access) and network.
            let profile = params["permissions"] as? [String: Any] ?? [:]
            let fs = profile["fileSystem"] as? [String: Any] ?? [:]
            var roots = ["read": fs["read"] as? [String] ?? [], "write": fs["write"] as? [String] ?? []]
            for entry in fs["entries"] as? [[String: Any]] ?? [] {
                let path = entry["path"] as? [String: Any] ?? [:]
                let special = path["value"] as? [String: Any]
                let kind = special?["kind"] as? String ?? "?"
                let sub = (special?["subpath"] as? String).map { "/" + $0 } ?? ""
                let label = ["root": "the whole disk", "minimal": "minimal system paths", "tmpdir": "the temp dir",
                             "slash_tmp": "/tmp", "project_roots": "project roots" + sub][kind]
                    ?? (kind == "unknown" ? (special?["path"] as? String ?? "?") + sub : "<\(kind)>\(sub)")
                let name = path["path"] as? String ?? path["pattern"] as? String ?? label
                roots[(entry["access"] as? String) ?? "?", default: []].append(name)
            }
            var lines = roots.sorted { $0.key < $1.key }.filter { !$0.value.isEmpty }
                .map { "\($0.key.capitalized): \($0.value.map(oneLine).joined(separator: ", "))" }
            if let on = (profile["network"] as? [String: Any])?["enabled"] as? Bool {
                lines.append("Network: \(on ? "enabled" : "disabled")")
            }
            if let cwd = params["cwd"] as? String { lines.append("In: \(oneLine(cwd))") }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// Wire path text on one line: an embedded newline must not forge extra card lines.
    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: "\\n")
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
            // TurnStartedNotification = { threadId, turn: Turn { id, … } }.
            let id = (params["turn"] as? [String: Any])?["id"] as? String
            return id.map { [.turnStarted(TurnID(raw: $0))] } ?? []

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
    static let commandApproval = "item/commandExecution/requestApproval"
    static let fileChangeApproval = "item/fileChange/requestApproval"
    static let permissionsApproval = "item/permissions/requestApproval"
    static let legacyCommandApproval = "execCommandApproval"
    static let legacyPatchApproval = "applyPatchApproval"

    static func approvalKind(for method: String) -> ApprovalRequest.Kind? {
        switch method {
        case commandApproval, legacyCommandApproval:
            return .command
        case fileChangeApproval, legacyPatchApproval:
            return .fileChange
        case permissionsApproval:
            return .permission
        default:
            return nil
        }
    }
}
