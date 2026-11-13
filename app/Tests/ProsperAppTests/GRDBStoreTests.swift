import GRDB
import XCTest
@testable import ProsperApp

/// #1003 (QA #107): the GRDB stores on tempDir() databases, never the user's Application
/// Support files: open, migrate an older schema, one write and read per table, a newer
/// schema, and a corrupt file (no trap, and the file the store could not read is not rewritten).

/// Fixture helpers. Synchronous so the GRDB calls never pick the async overloads.
private enum Fixture {
    static func exec(_ url: URL, _ sql: String) throws {
        let q = try DatabaseQueue(path: url.path)
        try q.write { db in try db.execute(sql: sql) }
    }

    static func doubles(_ url: URL, _ sql: String) throws -> [Double] {
        let q = try DatabaseQueue(path: url.path)
        return try q.read { db in try Double.fetchAll(db, sql: sql) }
    }

    static func columns(_ url: URL, _ table: String) throws -> Set<String> {
        let q = try DatabaseQueue(path: url.path)
        return try q.read { db in Set(try db.columns(in: table).map(\.name)) }
    }

    /// A file SQLite refuses with SQLITE_NOTADB.
    static func corrupt(_ url: URL) throws -> Data {
        let bytes = Data(String(repeating: "not a database\n", count: 300).utf8)
        try bytes.write(to: url)
        return bytes
    }
}

final class TypingHistoryStoreTests: XCTestCase {
    private let collectKey = "collectTypingHistory"

    func testEachTableTakesAWriteAndReadsItBack() async {
        let d = Preferences.defaults, saved = d.object(forKey: collectKey)
        defer { d.set(saved, forKey: collectKey) }
        d.set(true, forKey: collectKey)
        let dir = tempDir("typing-history")
        let store = TypingHistoryStore(directory: dir)

        await store.record("  hello there world  ", bundleId: "com.example.mail")
        await store.recordTrainingSample(prompt: "Dear team,", completion: " thanks", accepted: true,
                                         bundleId: "com.example.mail")
        await store.recordTrainingSample(prompt: "Hi", completion: " no", accepted: false)

        let entries = await store.entryCount()
        let byApp = await store.countsByBundle()
        let samples = await store.sampleCount()
        let accepted = await store.sampleCount(accepted: true)
        let dataset = await store.trainingDataset()
        XCTAssertEqual(entries, 1)
        XCTAssertEqual(byApp.map(\.bundleId), ["com.example.mail"])
        XCTAssertEqual(byApp.map(\.count), [1])
        XCTAssertEqual(samples, 2)
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(dataset, [LoRATrainingPair(prompt: "Dear team,", completion: " thanks")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("typing-history.sqlite").path))

        let reopened = TypingHistoryStore(directory: dir)
        let again = await reopened.entryCount()
        XCTAssertEqual(again, 1, "a second store on the same file reads the first one's rows")
        await reopened.deleteAll()
        let afterDelete = await reopened.entryCount()
        let samplesAfterDelete = await reopened.sampleCount()
        XCTAssertEqual(afterDelete, 0)
        XCTAssertEqual(samplesAfterDelete, 0)
    }

    /// A store from before lastUsed: the column is added and backfilled from ts, the samples
    /// table is created, and bench-host rows (com.prosper.*) are scrubbed on open.
    func testOlderSchemaIsMigratedOnOpen() async throws {
        let d = Preferences.defaults, saved = d.object(forKey: collectKey)
        defer { d.set(saved, forKey: collectKey) }
        d.set(true, forKey: collectKey)
        let dir = tempDir("typing-history-old")
        let url = dir.appendingPathComponent("typing-history.sqlite")
        try Fixture.exec(url, """
            CREATE TABLE entries (id INTEGER PRIMARY KEY AUTOINCREMENT, ts DOUBLE NOT NULL,
                                  text TEXT NOT NULL, wordCount INTEGER NOT NULL, bundleId TEXT);
            INSERT INTO entries (ts, text, wordCount, bundleId) VALUES (100, 'kept row', 2, 'com.example.mail');
            INSERT INTO entries (ts, text, wordCount, bundleId) VALUES (200, 'bench text', 2, 'com.prosper.e2ehost');
            """)
        let store = TypingHistoryStore(directory: dir)
        let entries = await store.entryCount()
        XCTAssertEqual(entries, 1, "the bench-host row is scrubbed")
        XCTAssertEqual(try Fixture.doubles(url, "SELECT lastUsed FROM entries"), [100], "lastUsed backfilled from ts")
        await store.recordTrainingSample(prompt: "Hello", completion: " there", accepted: true)
        let samples = await store.sampleCount()
        XCTAssertEqual(samples, 1, "the samples table exists after the migration")
    }

    /// A newer Prosper's extra nullable column is left alone; this build still reads and writes.
    func testNewerSchemaWithAnExtraColumnStillWorks() async throws {
        let d = Preferences.defaults, saved = d.object(forKey: collectKey)
        defer { d.set(saved, forKey: collectKey) }
        d.set(true, forKey: collectKey)
        let dir = tempDir("typing-history-new")
        let url = dir.appendingPathComponent("typing-history.sqlite")
        try Fixture.exec(url, """
            CREATE TABLE entries (id INTEGER PRIMARY KEY AUTOINCREMENT, ts DOUBLE NOT NULL,
                                  text TEXT NOT NULL, wordCount INTEGER NOT NULL, bundleId TEXT,
                                  lastUsed DOUBLE NOT NULL DEFAULT 0, mood TEXT);
            INSERT INTO entries (ts, text, wordCount, lastUsed, mood) VALUES (100, 'from the future', 3, 100, 'calm');
            """)
        let store = TypingHistoryStore(directory: dir)
        await store.record("written now")
        let entries = await store.entryCount()
        XCTAssertEqual(entries, 2)
        XCTAssertTrue(try Fixture.columns(url, "entries").contains("mood"), "the unknown column is kept")
    }

    func testCorruptFileDisablesTheStoreAndIsNotRewritten() async throws {
        let d = Preferences.defaults, saved = d.object(forKey: collectKey)
        defer { d.set(saved, forKey: collectKey) }
        d.set(true, forKey: collectKey)
        let dir = tempDir("typing-history-bad")
        let url = dir.appendingPathComponent("typing-history.sqlite")
        let bytes = try Fixture.corrupt(url)
        let store = TypingHistoryStore(directory: dir)
        await store.record("lost on purpose")
        let entries = await store.entryCount()
        let dataset = await store.trainingDataset()
        XCTAssertEqual(entries, 0)
        XCTAssertEqual(dataset, [])
        XCTAssertEqual(try Data(contentsOf: url), bytes, "a file the store could not read must not be overwritten")
    }
}

final class AppOverrideStoreTests: XCTestCase {
    /// Skips the one-time legacy-prefs import, which reads and writes Preferences.
    private let migratedKey = "appOverridesMigrated"

    func testAnOverrideRoundTripsAndAnEmptyOneIsDeleted() async {
        let d = Preferences.defaults, saved = d.object(forKey: migratedKey)
        defer { d.set(saved, forKey: migratedKey) }
        d.set(true, forKey: migratedKey)
        let cache = AppOverrideCache()
        let store = AppOverrideStore(directory: tempDir("app-overrides"), cache: cache)
        let ov = AppOverride(bundleId: "com.example.chat", enabled: false, customInstructions: "Keep it short.",
                             pasteAndMatchStyle: true, injectionChunkSize: 400)

        await store.setOverride(ov)
        let back = await store.override(for: "com.example.chat")
        let all = await store.allOverrides()
        XCTAssertEqual(back, ov)
        XCTAssertEqual(all, [ov])
        XCTAssertEqual(cache.override(for: "com.example.chat"), ov, "the store mirrors into its own cache")

        await store.setOverride(AppOverride(bundleId: "com.example.chat"))   // nothing set: deleted
        let afterEmpty = await store.allOverrides()
        XCTAssertEqual(afterEmpty, [])
        XCTAssertTrue(cache.override(for: "com.example.chat") == nil)
    }

    /// A table from before the insertion knobs gains its five columns and keeps its rows.
    func testOlderSchemaGainsTheInsertionColumns() async throws {
        let d = Preferences.defaults, saved = d.object(forKey: migratedKey)
        defer { d.set(saved, forKey: migratedKey) }
        d.set(true, forKey: migratedKey)
        let dir = tempDir("app-overrides-old")
        let url = dir.appendingPathComponent("app-overrides.sqlite")
        try Fixture.exec(url, """
            CREATE TABLE app_overrides (bundleId TEXT PRIMARY KEY, enabled BOOLEAN, customInstructions TEXT,
                tabToAccept BOOLEAN, smartQuotes BOOLEAN, minSizeThreshold INTEGER, forceEnhancedUI BOOLEAN,
                textMirroring BOOLEAN, surfaceOverride TEXT);
            INSERT INTO app_overrides (bundleId, enabled) VALUES ('com.example.mail', 1);
            """)
        let store = AppOverrideStore(directory: dir, cache: AppOverrideCache())
        let old = await store.override(for: "com.example.mail")
        XCTAssertEqual(old, AppOverride(bundleId: "com.example.mail", enabled: true))
        let knobs = AppOverride(bundleId: "com.example.notes", spaceKeyEvent: true, injectionChunkSize: 200)
        await store.setOverride(knobs)
        let back = await store.override(for: "com.example.notes")
        XCTAssertEqual(back, knobs)
        let columns = try Fixture.columns(url, "app_overrides")
        XCTAssertTrue(columns.isSuperset(of: ["pasteAndMatchStyle", "nonBreakingSpace", "spaceKeyEvent",
                                              "backspaceAfterPaste", "injectionChunkSize"]), "\(columns.sorted())")
    }

    func testCorruptFileDisablesTheStoreAndIsNotRewritten() async throws {
        let d = Preferences.defaults, saved = d.object(forKey: migratedKey)
        defer { d.set(saved, forKey: migratedKey) }
        d.set(true, forKey: migratedKey)
        let dir = tempDir("app-overrides-bad")
        let url = dir.appendingPathComponent("app-overrides.sqlite")
        let bytes = try Fixture.corrupt(url)
        let cache = AppOverrideCache()
        let store = AppOverrideStore(directory: dir, cache: cache)
        await store.setOverride(AppOverride(bundleId: "com.example.chat", enabled: true))
        let all = await store.allOverrides()
        XCTAssertEqual(all, [])
        XCTAssertTrue(cache.override(for: "com.example.chat") == nil)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "a file the store could not read must not be overwritten")
    }
}

final class AgentSessionStoreFileTests: XCTestCase {
    func testASecondStoreOnTheSameFileSeesTheSession() async {
        let dir = tempDir("agent-store-reopen")
        await AgentSessionStore(directory: dir).upsertSession(id: "api", cwd: "/Users/example/api",
                                                             model: "m", title: "fix the build")
        let listed = await AgentSessionStore(directory: dir).recentSessions()
        XCTAssertEqual(listed.map(\.id), ["api"])
        XCTAssertEqual(listed.first?.cwd, "/Users/example/api")
    }

    func testCorruptFileDisablesTheStoreAndIsNotRewritten() async throws {
        let dir = tempDir("agent-store-bad")
        let url = dir.appendingPathComponent("agent-sessions.sqlite")
        let bytes = try Fixture.corrupt(url)
        let store = AgentSessionStore(directory: dir)
        await store.upsertSession(id: "api", cwd: "/Users/example/api", model: "m", title: "t")
        let listed = await store.recentSessions()
        let transcript = await store.loadTranscript(id: "api")
        XCTAssertEqual(listed.count, 0)
        XCTAssertEqual(transcript.count, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "a file the store could not read must not be overwritten")
    }
}
