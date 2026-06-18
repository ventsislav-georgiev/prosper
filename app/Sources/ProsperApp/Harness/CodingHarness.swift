import Foundation

// Harness-agnostic coding-agent contract. Codex `app-server` is the first backend
// (`CodexHarness`), but every harness (oh-my-pi RPC, OpenCode serve, ACP) reduces to
// the same primitives: start → open a session → send a prompt → stream events →
// answer approvals → finish a turn. New backends ship as a `CodingHarness` adapter,
// not a rewrite.
//
// Design rule (from cross-harness impedance analysis): model everything as an event
// stream terminated by a synthesized `turnCompleted`. Backends that resolve a prompt
// request with a stop-reason (ACP) synthesize `turnCompleted` from that resolution.
// Optional features (forking, PTY exec, approval amendments) are gated behind
// `capabilities` so callers degrade gracefully.

// MARK: - Identifiers

/// Opaque session handle (thread/conversation id in the underlying harness).
struct SessionID: Hashable, Sendable, Codable { let raw: String }
/// Opaque per-prompt turn handle.
struct TurnID: Hashable, Sendable, Codable { let raw: String }
/// Opaque approval-request handle, replied to via `respondToApproval`.
struct ApprovalID: Hashable, Sendable, Codable { let raw: String }

// MARK: - Inputs / options

enum PromptInput: Sendable {
    case text(String)
    case image(path: String)   // gated by capabilities.images
}

/// Session-creation options. `sandbox`/`approvalPolicy` map to the backend's safety
/// model (Codex Seatbelt; others best-effort).
struct SessionOptions: Sendable {
    var cwd: String
    var model: String
    var approvalPolicy: ApprovalPolicy
    var sandbox: SandboxPolicy

    init(cwd: String, model: String,
         approvalPolicy: ApprovalPolicy = .onRequest,
         sandbox: SandboxPolicy = .workspaceWrite(networkAccess: false)) {
        self.cwd = cwd
        self.model = model
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
    }
}

enum ApprovalPolicy: String, Sendable { case never, onRequest = "on-request", onFailure = "on-failure", unlessTrusted = "unless-trusted" }

enum SandboxPolicy: Sendable {
    case readOnly
    case workspaceWrite(networkAccess: Bool)
    case dangerFullAccess
}

// MARK: - Approvals

enum ApprovalDecision: Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
    case acceptWithAmendment(String)   // codex-only; ignored where unsupported
}

struct ApprovalRequest: Sendable {
    enum Kind: Sendable { case command, fileChange, permission }
    let id: ApprovalID
    let kind: Kind
    let session: SessionID
    /// Human-readable summary for the UI (the command, the file, the requested perm).
    let summary: String
    /// Backend-specific detail (e.g. the full command argv, the unified diff).
    let detail: String?
}

// MARK: - Event payloads

struct ToolCall: Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
    var status: Status = .running
    /// Final command output (stdout+stderr) plus a one-line exit/duration footer,
    /// populated on completion. `nil` on start (the card streams deltas until then).
    var output: String? = nil
    enum Status: Sendable { case running, succeeded, failed }
}

struct ToolOutputChunk: Sendable {
    enum Stream: Sendable { case stdout, stderr }
    let stream: Stream
    let text: String
}

struct FileDiff: Sendable {
    let path: String
    let unifiedDiff: String
    enum Change: Sendable { case add, modify, delete }
    let change: Change
}

struct PlanStep: Sendable, Equatable {
    let title: String
    enum State: Sendable { case pending, inProgress, done }
    let state: State
}

struct TokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

enum TurnOutcome: Sendable {
    case completed
    case aborted
    case failed(String)
}

// MARK: - Event stream

enum HarnessEvent: Sendable {
    case sessionStarted(SessionID)
    case turnStarted(TurnID)
    case textDelta(turn: TurnID, itemID: String, text: String)
    case reasoningDelta(turn: TurnID, itemID: String, text: String)
    case toolCallStarted(ToolCall)
    case toolCallOutput(id: String, chunk: ToolOutputChunk)
    case toolCallCompleted(ToolCall)
    case fileChange(turn: TurnID, FileDiff)
    case planUpdated(turn: TurnID, [PlanStep])
    case approvalRequest(ApprovalRequest)
    case usage(TokenUsage)
    case turnCompleted(turn: TurnID, TurnOutcome)
    case error(HarnessError)
}

struct HarnessCapabilities: Sendable {
    let forking: Bool
    let liveApprovals: Bool
    let ptyExec: Bool
    let images: Bool
}

enum HarnessError: Error, Sendable {
    case notStarted
    case spawnFailed(String)
    case protocolError(String)
    case backendError(String)
    case timeout
}

// MARK: - Protocol

protocol CodingHarness: AnyObject, Sendable {
    func start() async throws
    func shutdown() async

    func newSession(_ opts: SessionOptions) async throws -> SessionID
    func resumeSession(_ id: SessionID) async throws -> SessionID
    func forkSession(_ id: SessionID) async throws -> SessionID   // capability-gated

    @discardableResult
    func sendPrompt(session: SessionID, input: [PromptInput]) async throws -> TurnID
    func steer(session: SessionID, turn: TurnID, input: [PromptInput]) async throws
    func abort(session: SessionID, turn: TurnID?) async throws
    func respondToApproval(_ id: ApprovalID, decision: ApprovalDecision) async throws

    /// Hot event stream. Multiple `events` accesses observe the same multicast stream.
    var events: AsyncStream<HarnessEvent> { get }
    var capabilities: HarnessCapabilities { get }
}
