import Foundation
import GRDB

/// Local, on-device typing-history store backing word-choice personalization
/// and the privacy "Existing data / Delete All" controls.
///
/// Records accepted completions only (never raw keystrokes) and only when
/// `Preferences.collectTypingHistory` is on. The SQLite file lives in the app's
/// Application Support directory with `NSFileProtectionComplete` so it is
/// encrypted at rest by the OS while the device is locked. (A SQLCipher-backed
/// build can swap `GRDB` for the `GRDB/SQLCipher` product without touching this
/// API.) Nothing is ever transmitted.
///
/// Implemented as an `actor`: callers hop off the main thread for all DB I/O.
actor TypingHistoryStore {
    static let shared = TypingHistoryStore()

    private var dbQueue: DatabaseQueue?
    private var didSetup = false

    /// One recorded accepted completion.
    private struct Entry: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "entries"
        var id: Int64?
        var ts: Double      // seconds since 1970
        var text: String
        var wordCount: Int
        var bundleId: String?  // frontmost app at accept time (per-app counts)
    }

    /// One recorded (prompt, completion) training pair for on-device LoRA (WS6).
    /// Accepted pairs are positive SFT examples; rejected pairs are stored only for
    /// A/B accounting and are never used as negative training data.
    private struct Sample: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "samples"
        var id: Int64?
        var ts: Double          // seconds since 1970
        var prompt: String      // text immediately before the cursor at suggest time
        var completion: String  // the suggested continuation
        var accepted: Bool      // true = accepted (positive SFT), false = dismissed
        var bundleId: String?   // frontmost app at suggest time
    }

    // MARK: - Training-text formatting (WS6)

    /// THE single source of truth for the training-text template (WS6). The trainer
    /// and any future inference-side adapter formatting MUST go through this so the
    /// text the adapter is trained on matches the text the model sees at inference.
    ///
    /// We do NOT reconstruct the full situational `buildCompletionPrompt` context
    /// here — that context (clipboard/OCR/app surface) is transient and not stored.
    /// Instead we mirror the *shape* of the inference task: the recorded `prompt`
    /// (the text before the cursor) followed by the accepted `completion`. The model
    /// continues `prompt` with `completion`, so concatenating them is the positive
    /// next-token target. Kept deliberately minimal and stable.
    static func trainingText(prompt: String, completion: String) -> String {
        prompt + completion
    }

    // MARK: - Setup

    /// Opens (and migrates) the database on first use. Idempotent.
    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        do {
            let fm = FileManager.default
            let base = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Prosper", isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)

            var config = Configuration()
            config.prepareDatabase { db in
                // At-rest encryption (WS7b). Active only when the GRDB build links
                // SQLCipher; `usePassphrase` is a SQLCipher-only symbol, so the call
                // is compiled out of plaintext builds. The key lives in the Keychain
                // (`DatabaseKey`), never on disk in plaintext. Adding the SQLCipher
                // SPM target flips this on with no API change to this store.
                #if canImport(SQLCipher)
                if let key = try? DatabaseKey.fetchOrCreate() {
                    try db.usePassphrase(key)
                }
                #endif
                // Best-effort OS-level encryption at rest while locked.
                try? db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            let url = base.appendingPathComponent("typing-history.sqlite")
            let queue = try DatabaseQueue(path: url.path, configuration: config)

            // Encrypt the file at rest (complete protection: unreadable while locked).
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )

            try queue.write { db in
                try db.create(table: Entry.databaseTableName, options: [.ifNotExists]) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("ts", .double).notNull()
                    t.column("text", .text).notNull()
                    t.column("wordCount", .integer).notNull()
                    t.column("bundleId", .text)
                }
                // Migration for stores created before bundleId existed.
                if try !db.columns(in: Entry.databaseTableName).contains(where: { $0.name == "bundleId" }) {
                    try db.alter(table: Entry.databaseTableName) { t in
                        t.add(column: "bundleId", .text)
                    }
                }
                // WS6: (prompt, completion) training pairs for on-device LoRA.
                try db.create(table: Sample.databaseTableName, options: [.ifNotExists]) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("ts", .double).notNull()
                    t.column("prompt", .text).notNull()
                    t.column("completion", .text).notNull()
                    t.column("accepted", .boolean).notNull()
                    t.column("bundleId", .text)
                }
            }
            dbQueue = queue
        } catch {
            NSLog("prosper: typing-history store unavailable: \(error.localizedDescription)")
            dbQueue = nil
        }
    }

    // MARK: - Write

    /// Records one accepted completion if collection is enabled. No-op otherwise.
    /// `bundleId` is the frontmost app, used for per-app input counts.
    func record(_ text: String, bundleId: String? = nil) {
        guard Preferences.collectTypingHistory else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setupIfNeeded()
        guard let dbQueue else { return }
        let words = trimmed.split { $0.isWhitespace }.count
        let entry = Entry(
            id: nil, ts: Date().timeIntervalSince1970,
            text: trimmed, wordCount: words, bundleId: bundleId
        )
        try? dbQueue.write { db in try entry.insert(db) }
    }

    /// Records one (prompt, completion) training pair if collection is enabled
    /// (same `collectTypingHistory` gate as `record`). Accepted pairs are positive
    /// SFT examples consumed by `trainingDataset`; rejected pairs are stored for A/B
    /// accounting only. No-op when collection is off or either field is empty.
    func recordTrainingSample(
        prompt: String, completion: String, accepted: Bool, bundleId: String? = nil
    ) {
        guard Preferences.collectTypingHistory else { return }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = completion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !c.isEmpty else { return }
        setupIfNeeded()
        guard let dbQueue else { return }
        let sample = Sample(
            id: nil, ts: Date().timeIntervalSince1970,
            prompt: prompt, completion: completion, accepted: accepted, bundleId: bundleId
        )
        try? dbQueue.write { db in try sample.insert(db) }
    }

    /// Accepted-completion counts grouped by app bundle id (most first). Used in
    /// Settings → Apps to show per-app collected-input counts.
    func countsByBundle() -> [(bundleId: String, count: Int)] {
        setupIfNeeded()
        guard let dbQueue else { return [] }
        let rows: [(String, Int)] = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundleId, COUNT(*) AS c FROM entries
                WHERE bundleId IS NOT NULL
                GROUP BY bundleId ORDER BY c DESC
            """).map { ($0["bundleId"] as String, $0["c"] as Int) }
        }) ?? []
        return rows.map { (bundleId: $0.0, count: $0.1) }
    }

    // MARK: - Read

    /// The user's most-frequent words (lowercased, length ≥ 4, alphabetic),
    /// most-frequent first. Used to bias completions when personalization is on.
    func frequentWords(limit: Int = 12) -> [String] {
        setupIfNeeded()
        guard let dbQueue else { return [] }
        let texts: [String] = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM entries ORDER BY ts DESC LIMIT 2000")
        }) ?? []
        guard !texts.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for text in texts {
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                guard token.count >= 4 else { continue }
                counts[String(token), default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    /// Number of stored entries (shown in Settings → Personalization).
    func entryCount() -> Int {
        setupIfNeeded()
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in try Entry.fetchCount(db) }) ?? 0
    }

    /// Positive-only SFT dataset for on-device LoRA training (WS6): the most recent
    /// ACCEPTED `(prompt, completion)` pairs. Returned as PAIRS (not pre-concatenated)
    /// so the trainer can wrap the prompt in the inference chat template — see
    /// `LoRATrainer.templatedText` (Risk 3 fix). Most recent first, capped at `limit`.
    /// Rejected pairs are intentionally excluded.
    func trainingDataset(limit: Int = 2000) -> [LoRATrainingPair] {
        setupIfNeeded()
        guard let dbQueue else { return [] }
        let rows: [Sample] = (try? dbQueue.read { db in
            try Sample
                .filter(Column("accepted") == true)
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return rows.map { LoRATrainingPair(prompt: $0.prompt, completion: $0.completion) }
    }

    /// Count of recorded training samples (WS6). `accepted == nil` counts all;
    /// otherwise counts only the matching arm. Used by the training gate + Settings.
    func sampleCount(accepted: Bool? = nil) -> Int {
        setupIfNeeded()
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in
            if let accepted {
                return try Sample.filter(Column("accepted") == accepted).fetchCount(db)
            }
            return try Sample.fetchCount(db)
        }) ?? 0
    }

    // MARK: - Delete

    /// Deletes all stored history (privacy "Delete All").
    func deleteAll() {
        setupIfNeeded()
        guard let dbQueue else { return }
        try? dbQueue.write { db in
            _ = try Entry.deleteAll(db)
            _ = try Sample.deleteAll(db)  // WS6 training pairs
        }
    }
}
