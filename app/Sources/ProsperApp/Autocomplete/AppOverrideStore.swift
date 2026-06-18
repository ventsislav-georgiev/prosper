import Foundation
import GRDB

/// One persisted per-app autocomplete override (WS3).
///
/// Keyed by `bundleId`. Every knob is **optional** so "unset" means *inherit* —
/// the resolver (`AppOverrideResolver`) falls back to the seeded default, then to
/// the existing `Preferences` value, then to the structural `AppProfile.Kind`
/// default. A user who never touches an app keeps today's behavior exactly.
///
/// Fields:
/// - `enabled` — completions on/off for this app (mirrors the old
///   `disabledBundleIds`/`completionsEnabledByDefault` gate).
/// - `customInstructions` — per-app addendum to the global completion prompt
///   (mirrors the old `perAppCustomInstructions[bundleId]`).
/// - `tabToAccept` — whether Tab accepts a word here (inverse of the old
///   `disableTabBundleIds` membership).
/// - `smartQuotes` — per-app smart-quote substitution preference (stored for the
///   editor; consumed by the typing path where smart quotes are applied).
/// - `minSizeThreshold` — minimum chars in the field before completing (anti-noise
///   for short fields like search boxes).
/// - `forceEnhancedUI` — force the mirror-window / enhanced ghost-text UI. Stored
///   only here; **consumed by WS4** (no behavior in this work-stream).
/// - `textMirroring` — force the text-mirroring fallback. Stored only here;
///   **consumed by WS4**.
/// - `surfaceOverride` — pin the writing `Surface` (raw case name) instead of the
///   inferred one, so the user can say "treat this app as email".
struct AppOverride: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "app_overrides"

    /// Frontmost-app bundle id. Primary key (text).
    var bundleId: String
    var enabled: Bool?
    var customInstructions: String?
    var tabToAccept: Bool?
    var smartQuotes: Bool?
    var minSizeThreshold: Int?
    var forceEnhancedUI: Bool?
    var textMirroring: Bool?
    /// Raw `AppProfile.Surface` case ("chat", "email", …), or nil to infer.
    var surfaceOverride: String?

    init(
        bundleId: String,
        enabled: Bool? = nil,
        customInstructions: String? = nil,
        tabToAccept: Bool? = nil,
        smartQuotes: Bool? = nil,
        minSizeThreshold: Int? = nil,
        forceEnhancedUI: Bool? = nil,
        textMirroring: Bool? = nil,
        surfaceOverride: String? = nil
    ) {
        self.bundleId = bundleId
        self.enabled = enabled
        self.customInstructions = customInstructions
        self.tabToAccept = tabToAccept
        self.smartQuotes = smartQuotes
        self.minSizeThreshold = minSizeThreshold
        self.forceEnhancedUI = forceEnhancedUI
        self.textMirroring = textMirroring
        self.surfaceOverride = surfaceOverride
    }

    /// True when no knob is set — a fully-inherited row carries no information and
    /// can be deleted instead of stored (keeps the table sparse).
    var isEmpty: Bool {
        enabled == nil && customInstructions == nil && tabToAccept == nil
            && smartQuotes == nil && minSizeThreshold == nil && forceEnhancedUI == nil
            && textMirroring == nil && surfaceOverride == nil
    }
}

/// Persisted, user-editable per-app autocomplete override store (WS3).
///
/// Consolidates the scattered per-app `Preferences` (`perAppCustomInstructions`,
/// `disabledBundleIds`/`enabledBundleIds`, `disableTabBundleIds`, …) into a single
/// GRDB-backed table the Settings UI can edit as a list + detail editor (the UI
/// itself lands in a later task; this store leaves a clean CRUD API for it).
///
/// Storage mirrors `TypingHistoryStore`: a `DatabaseQueue` at
/// `Application Support/Prosper/app-overrides.sqlite` with `NSFileProtectionComplete`
/// (encrypted at rest while the device is locked), WAL journaling, and the same
/// `#if canImport(SQLCipher)` passphrase hook (active only in SQLCipher builds).
///
/// Implemented as an `actor` so all DB I/O hops off the main thread. Because the
/// autocomplete hot path runs on every keystroke and must not `await`, the store
/// also publishes a **synchronous read cache** (`AppOverrideCache`) refreshed on
/// every write — callers read overrides synchronously, exactly as they read
/// `Preferences`.
actor AppOverrideStore {
    static let shared = AppOverrideStore()

    private var dbQueue: DatabaseQueue?
    private var didSetup = false

    // MARK: - Setup

    /// Opens (and migrates) the database on first use, then primes the sync cache.
    /// Idempotent.
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
                // is compiled out of plaintext builds. Same Keychain key as the
                // typing-history store — one passphrase guards all Prosper DBs.
                #if canImport(SQLCipher)
                if let key = try? DatabaseKey.fetchOrCreate() {
                    try db.usePassphrase(key)
                }
                #endif
                try? db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            let url = base.appendingPathComponent("app-overrides.sqlite")
            let queue = try DatabaseQueue(path: url.path, configuration: config)

            // Encrypt the file at rest (complete protection: unreadable while locked).
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )

            try queue.write { db in
                try db.create(table: AppOverride.databaseTableName, options: [.ifNotExists]) { t in
                    t.column("bundleId", .text).primaryKey()
                    t.column("enabled", .boolean)
                    t.column("customInstructions", .text)
                    t.column("tabToAccept", .boolean)
                    t.column("smartQuotes", .boolean)
                    t.column("minSizeThreshold", .integer)
                    t.column("forceEnhancedUI", .boolean)
                    t.column("textMirroring", .boolean)
                    t.column("surfaceOverride", .text)
                }
            }
            dbQueue = queue
            // One-time migration of legacy per-app prefs into the store.
            migrateLegacyPrefsIfNeeded(queue)
            // Prime the synchronous read cache from the freshly-opened DB.
            refreshCache(queue)
        } catch {
            NSLog("prosper: app-override store unavailable: \(error.localizedDescription)")
            dbQueue = nil
        }
    }

    // MARK: - CRUD

    /// The stored override for a bundle id, or nil if the user has set none.
    func override(for bundleId: String) -> AppOverride? {
        setupIfNeeded()
        guard let dbQueue else { return nil }
        return try? dbQueue.read { db in try AppOverride.fetchOne(db, key: bundleId) }
    }

    /// Inserts or replaces an override. An all-unset (`isEmpty`) override is deleted
    /// instead of stored, so inheriting rows never accumulate. Refreshes the cache.
    func setOverride(_ override: AppOverride) {
        setupIfNeeded()
        guard let dbQueue else { return }
        if override.isEmpty {
            try? dbQueue.write { db in _ = try AppOverride.deleteOne(db, key: override.bundleId) }
        } else {
            try? dbQueue.write { db in try override.save(db) }
        }
        refreshCache(dbQueue)
    }

    /// All stored overrides, ordered by bundle id (stable for the list editor).
    func allOverrides() -> [AppOverride] {
        setupIfNeeded()
        guard let dbQueue else { return [] }
        return (try? dbQueue.read { db in
            try AppOverride.order(Column("bundleId")).fetchAll(db)
        }) ?? []
    }

    /// Deletes a single app's override (back to fully-inherited). Refreshes the cache.
    func delete(bundleId: String) {
        setupIfNeeded()
        guard let dbQueue else { return }
        try? dbQueue.write { db in _ = try AppOverride.deleteOne(db, key: bundleId) }
        refreshCache(dbQueue)
    }

    /// Deletes every override (privacy / "reset all per-app settings").
    func deleteAll() {
        setupIfNeeded()
        guard let dbQueue else { return }
        try? dbQueue.write { db in _ = try AppOverride.deleteAll(db) }
        refreshCache(dbQueue)
    }

    // MARK: - Sync cache plumbing

    /// Reloads every override into the synchronous `AppOverrideCache` snapshot.
    /// Called after every write so the hot path never observes stale data.
    private func refreshCache(_ queue: DatabaseQueue) {
        let rows = (try? queue.read { db in try AppOverride.fetchAll(db) }) ?? []
        AppOverrideCache.shared.replace(with: rows)
    }

    /// Eagerly opens the DB and primes the cache at launch (call once from app
    /// startup) so the first keystroke reads a warm cache instead of an empty one.
    func warmUp() {
        setupIfNeeded()
    }

    // MARK: - Legacy migration

    /// One-time migration of the old scattered per-app prefs into the store, so the
    /// new editor shows what the user already configured. Guarded by a
    /// `Preferences` flag; runs once. The legacy `Preferences` accessors keep
    /// working as fallback reads (see `AppOverrideResolver`), so nothing breaks if
    /// migration is skipped or partial.
    ///
    /// Mapped:
    /// - `perAppCustomInstructions[id]` → `customInstructions`
    /// - membership in `disabledBundleIds` → `enabled = false`
    /// - membership in `enabledBundleIds` → `enabled = true`
    /// - membership in `disableTabBundleIds` → `tabToAccept = false`
    private func migrateLegacyPrefsIfNeeded(_ queue: DatabaseQueue) {
        guard !Preferences.appOverridesMigrated else { return }

        let perApp = Preferences.perAppCustomInstructions
        let disabled = Preferences.disabledBundleIds
        let enabled = Preferences.enabledBundleIds
        let disableTab = Preferences.disableTabBundleIds

        // Union of every bundle id mentioned by a legacy per-app pref.
        var ids = Set(perApp.keys)
        ids.formUnion(disabled)
        ids.formUnion(enabled)
        ids.formUnion(disableTab)

        var merged: [AppOverride] = []
        for id in ids {
            var ov = AppOverride(bundleId: id)
            if let instr = perApp[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !instr.isEmpty {
                ov.customInstructions = instr
            }
            // Disabled wins over enabled if (pathologically) in both lists.
            if disabled.contains(id) {
                ov.enabled = false
            } else if enabled.contains(id) {
                ov.enabled = true
            }
            if disableTab.contains(id) {
                ov.tabToAccept = false
            }
            if !ov.isEmpty { merged.append(ov) }
        }

        if !merged.isEmpty {
            try? queue.write { db in
                for ov in merged { try ov.save(db) }
            }
        }
        Preferences.appOverridesMigrated = true
    }
}

/// Synchronous, thread-safe snapshot of all per-app overrides for the autocomplete
/// hot path. The `AppOverrideStore` actor owns the DB; this cache mirrors its rows
/// so callers on the keystroke path read overrides without `await`ing the actor —
/// exactly how `Preferences` is read synchronously.
///
/// A plain `NSLock` guards a `[String: AppOverride]` dict. Reads are O(1) and
/// lock-free-ish (one short critical section); writes happen only when the store
/// mutates, off the hot path.
final class AppOverrideCache: @unchecked Sendable {
    static let shared = AppOverrideCache()

    private let lock = NSLock()
    private var byBundleId: [String: AppOverride] = [:]

    private init() {}

    /// Replaces the whole snapshot (called by the store after every write).
    func replace(with overrides: [AppOverride]) {
        lock.lock()
        byBundleId = Dictionary(uniqueKeysWithValues: overrides.map { ($0.bundleId, $0) })
        lock.unlock()
    }

    /// The cached override for a bundle id, or nil. Safe to call from any thread.
    func override(for bundleId: String?) -> AppOverride? {
        guard let bundleId else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return byBundleId[bundleId]
    }
}
