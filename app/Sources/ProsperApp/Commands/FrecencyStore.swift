import Foundation

/// Local, on-device "frecency" (frequency × recency) of file engagements, used to
/// float a user's most-opened files toward the top of `f ` search results —
/// matching how Alfred/Raycast rank by usage, not just name match.
///
/// Storage is a small `path → { count, lastUsed }` map in `UserDefaults` (same
/// dependency-free precedent as `CompletionStats`; the data is tiny and a full
/// GRDB store would be overkill). Local-only, never transmitted, and clearable.
///
/// `@unchecked Sendable`: the only shared mutable state is `UserDefaults`
/// (thread-safe) guarded by a lock for the read-modify-write bump.
final class FrecencyStore: @unchecked Sendable {

    static let shared = FrecencyStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    /// `defaults`/`storageKey` are injectable so tests get an isolated suite.
    init(defaults: UserDefaults = .standard, storageKey: String = "files.frecency.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// One file's running engagement: how many times acted on, and when last.
    struct Entry: Codable, Equatable {
        var count: Int
        var lastUsed: TimeInterval  // epoch seconds
    }

    // MARK: - Mutation

    /// Records one engagement with `path` (open / reveal / quick look / …). Bumps
    /// the count and stamps the time. No-op for an empty path.
    func record(path: String, now: TimeInterval = Date().timeIntervalSince1970) {
        guard !path.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var map = load()
        var e = map[path] ?? Entry(count: 0, lastUsed: now)
        e.count += 1
        e.lastUsed = now
        map[path] = e
        // Keep the table bounded: if it grows large, drop the lowest-scoring half
        // so a long-lived install doesn't accumulate unbounded paths.
        if map.count > 2000 {
            let ranked = map.sorted { Self.score($0.value, now: now) > Self.score($1.value, now: now) }
            map = Dictionary(uniqueKeysWithValues: ranked.prefix(1000).map { ($0.key, $0.value) })
        }
        save(map)
    }

    /// Forgets all recorded engagements (Settings "clear" affordance).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Lookup

    /// Frecency boost for a single path (0 when never engaged). Used as a ranking
    /// signal blended in by `FileSearchEngine.rank`.
    func boost(path: String, now: TimeInterval = Date().timeIntervalSince1970) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let e = load()[path] else { return 0 }
        return Self.score(e, now: now)
    }

    /// Boosts for a set of paths in one read (avoids re-decoding per path).
    func boosts(for paths: [String], now: TimeInterval = Date().timeIntervalSince1970) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        let map = load()
        var out: [String: Double] = [:]
        for p in paths { if let e = map[p] { out[p] = Self.score(e, now: now) } }
        return out
    }

    // MARK: - Scoring (pure → unit-testable)

    /// Frecency score: usage count decayed by recency, with a ~30-day half-life
    /// so a file opened often-but-long-ago fades behind one opened recently.
    static func score(_ e: Entry, now: TimeInterval) -> Double {
        guard e.count > 0 else { return 0 }
        let ageDays = max(0, (now - e.lastUsed) / 86_400)
        let recency = exp(-ageDays / 30.0)  // 1.0 today → ~0.37 at 30 days → ~0.14 at 60
        return Double(e.count) * recency
    }

    // MARK: - Persistence

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ map: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
