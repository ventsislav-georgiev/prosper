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

enum ApprovalPolicy: String, Sendable { case never, onRequest = "on-request", untrusted }

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
    /// Codex-only: accept and allow commands starting with this argv prefix from now on
    /// (the request's `proposedExecpolicyAmendment`). Plain accept where unsupported.
    case acceptWithAmendment([String])
}

struct ApprovalRequest: Sendable {
    enum Kind: Sendable { case command, fileChange, permission }
    let id: ApprovalID
    let kind: Kind
    let session: SessionID
    /// Human-readable summary for the UI (the command, the file, the requested perm), display-ready:
    /// the harness applies `CardText.ltr` when it builds the request, so the card does no work.
    let summary: String
    /// Backend-specific detail (e.g. the full command argv, the unified diff), display-ready and
    /// capped (`CardText.detail`).
    let detail: String?
}

// MARK: - Wire text

/// Harness text escaped for display: approval cards (CodexHarness) and the transcript's
/// tool and file-diff cards (#358, at AgentController ingress and AgentSessionStore restore).
/// Every function is idempotent, so restoring already-escaped history leaves it unchanged.
enum WireText {
    /// Wire text on one card line: an embedded newline must not forge extra card lines, and
    /// a control (Cc: C0, DEL, C1), a format scalar (bidi override, zero-width) or another
    /// default-ignorable one (Hangul filler, variation selector) shows as `\u{…}` rather than
    /// reordering or hiding what is granted. A run of 3 or more whitespace scalars (any Zs —
    /// space, U+00A0, U+2003, U+3000 — or tab, mixed freely) becomes one `␠×N` marker with the
    /// run's total scalar count, so padding can't push a command's tail out of view; a single
    /// or double space is left alone (a lone tab still escapes as `\u{9}`).
    static func oneLine(_ s: String) -> String {
        let escape = escaped
        var out = "", run: [Unicode.Scalar] = []
        func flush() {
            out += run.count >= 3 ? "␠×\(run.count)" : run.map(escape).joined()
            run = []
        }
        for u in s.components(separatedBy: .newlines).joined(separator: "\\n").unicodeScalars {
            if u == "\t" || u.properties.generalCategory == .spaceSeparator { run.append(u); continue }
            flush()
            out += escape(u)
        }
        flush()
        return out
    }

    /// #357: a file diff keeps its real newlines and indentation (no whitespace-run collapsing, a
    /// diff's indentation is content), but every other scalar goes through `escaped`, so a bidi
    /// override in the body (Trojan Source) shows as `\u{202E}` instead of reordering the card.
    /// A tab stays raw: it hides nothing. A CRLF line end reads as a plain newline; a lone `\r`
    /// (which can overprint text in some renderers) shows as `\u{D}`.
    static func multiLine(_ s: String) -> String {
        // Split on scalars: as Characters, "\r\n" is one cluster that never equals "\n".
        s.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.map { $0 == "\t" ? "\t" : escaped($0) }.joined() }
            .joined(separator: "\n")
    }

    /// A control (Cc), a format scalar (Cf), a default-ignorable one, or a line/paragraph
    /// separator (Zl/Zp, U+2028/U+2029) as `\u{…}` text. Zl/Zp matter only to `multiLine`:
    /// `oneLine` has already split them out with `.newlines`.
    static func escaped(_ u: Unicode.Scalar) -> String {
        [.control, .format, .lineSeparator, .paragraphSeparator].contains(u.properties.generalCategory)
            || u.properties.isDefaultIgnorableCodePoint
            ? "\\u{\(String(u.value, radix: 16, uppercase: true))}" : String(u)
    }

    /// #358: command output drops well-formed SGR colour codes (`ESC [ … m`) first, then goes
    /// through `multiLine`, so any other ESC sequence (an OSC title, a cursor move) shows escaped.
    static func toolOutput(_ s: String) -> String {
        multiLine(s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression))
    }
}

/// #354: approval-card text in logical order. Bidi rule N1 gives a neutral (space, `>`, `|`)
/// between two RTL words (or Arabic-Indic digits) their direction, so `echo א > ב` would draw
/// as `echo ב < א`; an LRM after every neutral pins it left-to-right. The summary comes through
/// `WireText.oneLine` and a file diff through `WireText.multiLine`, both of which escape Cf (LRM included), so `ltr`
/// never sees a raw bidi control. Swift has no bidi class, so the gate is pure ASCII, which
/// can hold no RTL or AN scalar: ASCII is returned as is and copies off the card clean;
/// anything else (an `é` path too, over-inclusively) gets the LRMs, and a copy carries them.
/// The LRM goes after a whole grapheme cluster whose first scalar is Zs/P*/S*, never inside one
/// (combining marks, niqqud, a virama conjunct, a flag stay intact).
/// #359: applied once where the harness builds the `ApprovalRequest` (off the main thread), not in
/// the view body, which reran it on every render (a 1 MB non-ASCII diff cost ~85 ms each time).
enum CardText {
    /// A detail longer than this many Characters keeps only its head on the card: codex sends no
    /// diff cap, and a multi-megabyte diff would stall the card's layout. 256 K reads whole far
    /// past anything a user reviews in a 160 pt box; the summary is never capped (#323 wants it whole).
    static let detailCap = 256 * 1024

    /// The approval detail as the card shows it: the first `detailCap` Characters through `ltr`,
    /// plus a final "… N more characters not shown" line when there was more.
    static func detail(_ s: String) -> String {
        guard let cut = s.index(s.startIndex, offsetBy: detailCap, limitedBy: s.endIndex), cut < s.endIndex
        else { return ltr(s) }
        return ltr(String(s[..<cut])) + "\n… \(s[cut...].count) more characters not shown"
    }

    private static let neutral: Set<Unicode.GeneralCategory> = [
        .spaceSeparator, .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
        .initialPunctuation, .finalPunctuation, .otherPunctuation,
        .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
    ]

    static func ltr(_ s: String) -> String {
        guard !s.utf8.allSatisfy({ $0 < 0x80 }) else { return s }
        var out = ""
        for c in s {
            out.append(c)
            if let first = c.unicodeScalars.first, neutral.contains(first.properties.generalCategory) {
                out.unicodeScalars.append("\u{200E}")
            }
        }
        return out
    }
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
    /// `options` re-applies the current approval policy and sandbox; cwd/model stay the thread's.
    func resumeSession(_ id: SessionID, options: SessionOptions) async throws -> SessionID
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
