import Foundation
import GRDB

/// On-device persistence for coding-agent sessions so a goal-driven run survives an
/// app relaunch: the transcript is restored into `ChatWindow` and the underlying
/// Codex thread is re-attached via `CodingHarness.resumeSession` (Codex persists the
/// thread itself under `CODEX_HOME/sessions`; this store persists the *display*
/// transcript + the metadata needed to find and relabel it).
///
/// Same storage discipline as `TypingHistoryStore`: a SQLite file in Application
/// Support with `NSFileProtectionComplete`, WAL, and the SQLCipher passphrase hook
/// (compiled out of plaintext builds). Nothing leaves the device.
///
/// The whole transcript is stored as one JSON column per session rather than a
/// normalized messages table: the agent mutates items in place (delta accumulation),
/// so a per-turn snapshot of the rendered array is both simpler and exactly what the
/// UI needs to redraw. Sessions are keyed by the harness `SessionID.raw` (the Codex
/// thread id) so resume can hand the same id back to the harness.
///
/// `actor`: callers hop off the main thread for all DB I/O.
actor AgentSessionStore {
    static let shared = AgentSessionStore()

    private var dbQueue: DatabaseQueue?
    private var didSetup = false

    /// Directory the SQLite file lives in. `nil` → the shared Application Support
    /// location used in production. Tests inject a private temp directory so each run
    /// starts from a clean, isolated database (no shared WAL/state across runs).
    private let overrideDirectory: URL?

    init(directory: URL? = nil) {
        self.overrideDirectory = directory
    }

    /// One persisted session row. `transcript` is a JSON-encoded `[PersistedItem]`.
    private struct SessionRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "agent_sessions"
        var id: String        // SessionID.raw (Codex thread id) — primary key
        var createdAt: Double  // seconds since 1970
        var updatedAt: Double
        var cwd: String
        var model: String
        var title: String      // first goal, truncated — the history-list label
        var transcript: String // JSON [PersistedItem]
    }

    /// A lightweight session descriptor for the history list (no transcript payload).
    struct Summary: Sendable, Identifiable {
        let id: String
        let title: String
        let cwd: String
        let model: String
        let updatedAt: Date
    }

    // MARK: - Setup

    /// Opens (and migrates) the database on first use. Idempotent.
    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        do {
            let fm = FileManager.default
            let base = try overrideDirectory ?? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Prosper", isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)

            var config = Configuration()
            config.prepareDatabase { db in
                // At-rest encryption, active only on a SQLCipher-linked build (same
                // pattern as TypingHistoryStore). Key from the Keychain/device.key.
                #if canImport(SQLCipher)
                // A key failure must NOT silently downgrade to plaintext: throw so
                // the open fails and the store stays disabled (catch below).
                try db.usePassphrase(DatabaseKey.fetchOrCreate())
                #endif
                try? db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            let url = base.appendingPathComponent("agent-sessions.sqlite")
            let queue = try DatabaseQueue(path: url.path, configuration: config)

            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )

            try queue.write { db in
                try db.create(table: SessionRow.databaseTableName, options: [.ifNotExists]) { t in
                    t.primaryKey("id", .text)
                    t.column("createdAt", .double).notNull()
                    t.column("updatedAt", .double).notNull()
                    t.column("cwd", .text).notNull()
                    t.column("model", .text).notNull()
                    t.column("title", .text).notNull()
                    t.column("transcript", .text).notNull()
                }
            }
            dbQueue = queue
            #if !canImport(SQLCipher)
            // Loud marker: at-rest encryption silently regressing to plaintext is
            // the failure mode we never want unnoticed (transcripts hold code).
            NSLog("prosper: agent-session store is NOT encrypted (GRDB built without SQLCipher)")
            #endif
        } catch {
            NSLog("prosper: agent-session store unavailable: \(error.localizedDescription)")
            dbQueue = nil
        }
    }

    // MARK: - Write

    /// Create or refresh a session's metadata (called when a session opens). Preserves
    /// an existing `createdAt`/`title`/`transcript`; only refreshes `updatedAt` and the
    /// mutable cwd/model. The title is seeded from `title` only on first insert.
    func upsertSession(id: String, cwd: String, model: String, title: String) {
        setupIfNeeded()
        guard let dbQueue else { return }
        let now = Date().timeIntervalSince1970
        try? dbQueue.write { db in
            if var existing = try SessionRow.fetchOne(db, key: id) {
                existing.updatedAt = now
                existing.cwd = cwd
                existing.model = model
                try existing.update(db)
            } else {
                let row = SessionRow(id: id, createdAt: now, updatedAt: now, cwd: cwd,
                              model: model, title: Self.clipTitle(title), transcript: "[]")
                try row.insert(db)
            }
        }
    }

    /// Snapshot the rendered transcript for a session (called on each turn completion).
    /// No-op if the session row does not exist yet.
    func saveTranscript(id: String, items: [AgentItem]) {
        setupIfNeeded()
        guard let dbQueue else { return }
        let json = Self.encode(items)
        let now = Date().timeIntervalSince1970
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(SessionRow.databaseTableName) SET transcript = ?, updatedAt = ? WHERE id = ?",
                arguments: [json, now, id]
            )
        }
    }

    // MARK: - Read

    /// Recent sessions, newest first, for the history picker.
    func recentSessions(limit: Int = 30) -> [Summary] {
        setupIfNeeded()
        guard let dbQueue else { return [] }
        let rows: [SessionRow] = (try? dbQueue.read { db in
            try SessionRow.order(Column("updatedAt").desc).limit(limit).fetchAll(db)
        }) ?? []
        return rows.map {
            Summary(id: $0.id, title: $0.title, cwd: $0.cwd, model: $0.model,
                    updatedAt: Date(timeIntervalSince1970: $0.updatedAt))
        }
    }

    /// Load a session's persisted transcript for display on resume.
    func loadTranscript(id: String) -> [AgentItem] {
        setupIfNeeded()
        guard let dbQueue else { return [] }
        let json: String? = try? dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT transcript FROM \(SessionRow.databaseTableName) WHERE id = ?",
                arguments: [id])
        }
        guard let json else { return [] }
        return Self.decode(json)
    }

    /// The working directory a session ran in (used to restore cwd on resume).
    func cwd(id: String) -> String? {
        setupIfNeeded()
        guard let dbQueue else { return nil }
        return try? dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT cwd FROM \(SessionRow.databaseTableName) WHERE id = ?",
                arguments: [id])
        } ?? nil
    }

    /// Rename a session (the history-list label). No-op if the row doesn't exist.
    func renameSession(id: String, title: String) {
        setupIfNeeded()
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(SessionRow.databaseTableName) SET title = ? WHERE id = ?",
                arguments: [Self.clipTitle(title), id])
        }
    }

    // MARK: - Delete

    func deleteSession(id: String) {
        setupIfNeeded()
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM \(SessionRow.databaseTableName) WHERE id = ?", arguments: [id])
        }
    }

    /// Privacy "Delete All" — wipe every persisted agent session.
    func deleteAll() {
        setupIfNeeded()
        guard let dbQueue else { return }
        try? dbQueue.write { db in _ = try SessionRow.deleteAll(db) }
    }

    // MARK: - Title helper

    private static func clipTitle(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        return oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
    }

    // MARK: - Transcript codec

    /// Codable mirror of `AgentItem` (an enum with associated values, not itself
    /// Codable). Optional fields carry per-kind payload; the `kind` tag selects them.
    private struct PersistedItem: Codable {
        var kind: String
        var id: String
        var text: String?
        var reasoning: Bool?
        var name: String?
        var args: String?
        var status: String?   // toolCall: running/succeeded/failed
        var output: String?
        var path: String?
        var diff: String?
        var change: String?   // fileDiff: add/modify/delete
        var steps: [Step]?
        struct Step: Codable { var title: String; var state: String } // pending/inProgress/done
    }

    private static func encode(_ items: [AgentItem]) -> String {
        let dtos = items.map(persist)
        guard let data = try? JSONEncoder().encode(dtos),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decode(_ json: String) -> [AgentItem] {
        guard let data = json.data(using: .utf8),
              let dtos = try? JSONDecoder().decode([PersistedItem].self, from: data) else { return [] }
        return dtos.compactMap(restore)
    }

    private static func persist(_ item: AgentItem) -> PersistedItem {
        switch item {
        case .user(let id, let text):
            return PersistedItem(kind: "user", id: id, text: text)
        case .assistant(let id, let text, let reasoning):
            return PersistedItem(kind: "assistant", id: id, text: text, reasoning: reasoning)
        case .toolCall(let id, let name, let args, let status, let output):
            return PersistedItem(kind: "toolCall", id: id, name: name, args: args,
                                 status: statusString(status), output: output)
        case .fileDiff(let id, let path, let diff, let change):
            return PersistedItem(kind: "fileDiff", id: id, path: path, diff: diff,
                                 change: changeString(change))
        case .plan(let id, let steps):
            return PersistedItem(kind: "plan", id: id,
                                 steps: steps.map { .init(title: $0.title, state: stateString($0.state)) })
        case .error(let id, let message):
            return PersistedItem(kind: "error", id: id, text: message)
        case .note(let id, let text):
            return PersistedItem(kind: "note", id: id, text: text)
        }
    }

    private static func restore(_ d: PersistedItem) -> AgentItem? {
        switch d.kind {
        case "user":
            return .user(id: d.id, text: d.text ?? "")
        case "assistant":
            return .assistant(id: d.id, text: d.text ?? "", reasoning: d.reasoning ?? false)
        case "toolCall":
            return .toolCall(id: d.id, name: d.name ?? "", args: d.args ?? "",
                             status: status(from: d.status), output: d.output ?? "")
        case "fileDiff":
            return .fileDiff(id: d.id, path: d.path ?? "", diff: d.diff ?? "",
                             change: change(from: d.change))
        case "plan":
            return .plan(id: d.id, steps: (d.steps ?? []).map {
                PlanStep(title: $0.title, state: state(from: $0.state))
            })
        case "error":
            return .error(id: d.id, message: d.text ?? "")
        case "note":
            return .note(id: d.id, text: d.text ?? "")
        default:
            return nil
        }
    }

    private static func statusString(_ s: ToolCall.Status) -> String {
        switch s { case .running: return "running"; case .succeeded: return "succeeded"; case .failed: return "failed" }
    }
    private static func status(from s: String?) -> ToolCall.Status {
        switch s { case "succeeded": return .succeeded; case "failed": return .failed; default: return .running }
    }
    private static func changeString(_ c: FileDiff.Change) -> String {
        switch c { case .add: return "add"; case .modify: return "modify"; case .delete: return "delete" }
    }
    private static func change(from c: String?) -> FileDiff.Change {
        switch c { case "add": return .add; case "delete": return .delete; default: return .modify }
    }
    private static func stateString(_ s: PlanStep.State) -> String {
        switch s { case .pending: return "pending"; case .inProgress: return "inProgress"; case .done: return "done" }
    }
    private static func state(from s: String?) -> PlanStep.State {
        switch s { case "inProgress": return .inProgress; case "done": return .done; default: return .pending }
    }
}
