import Foundation

/// Reads/writes the snippets the Lua `snippets` extension and the inline expander
/// share, following the exact persistence pattern `QuicklinkStore` uses.
///
/// Two runtime maps live in UserDefaults (what the Lua extension reads through
/// `host.snippets` / `host.prefs`): a JSON array of snippet objects under
/// `ext.com.prosper.snippets.items`, and a JSON array of collection objects under
/// `ext.com.prosper.snippets.collections`.
///
/// On top of UserDefaults, both are mirrored to a human-editable file at
/// `~/.config/prosper/snippets.json` so they can be exported, version-controlled,
/// or bulk-imported. `bootstrap()` (called at launch) reconciles the two: if the
/// file was edited externally since we last wrote it, the file wins and is
/// imported into UserDefaults; otherwise UserDefaults wins and the file is
/// rewritten (capturing edits made through the palette / Settings since launch).
enum SnippetStore {
    static let extensionID = "com.prosper.snippets"
    private static var itemsKey: String { "ext.\(extensionID).items" }
    private static var collectionsKey: String { "ext.\(extensionID).collections" }
    /// Snapshot of the JSON we last wrote to disk, used to detect external edits.
    private static var mirrorKey: String { "ext.\(extensionID).diskMirror" }
    private static var changeTokenKey: String { "ext.\(extensionID).changeToken" }

    /// UserDefaults backing the runtime maps + mirror. Normally `.standard`; under
    /// e2e (PROSPER_HOME set) a throwaway suite, wiped at launch so `bootstrap()`
    /// re-imports the seeded `snippets.json` instead of merging the real mirror.
    nonisolated(unsafe) private static let defaults: UserDefaults = {
        let suiteName = "com.prosper.snippets.e2e"
        if E2EConfig.isolated, let suite = UserDefaults(suiteName: suiteName) {
            suite.removePersistentDomain(forName: suiteName)
            return suite
        }
        return .standard
    }()

    /// Bumped on every mutation so the inline expander can cheaply detect when its
    /// cached keyword list is stale and rebuild it. Backed by UserDefaults (rather
    /// than an in-memory static var) to stay concurrency-safe under Swift 6.
    static var changeToken: Int { defaults.integer(forKey: changeTokenKey) }

    /// Human-editable export/import file: `~/.config/prosper/snippets.json`.
    static var fileURL: URL {
        E2EConfig.home
            .appendingPathComponent(".config/prosper/snippets.json", isDirectory: false)
    }

    // MARK: - Codable on-disk shapes

    /// One on-disk snippet. `text` is the body (plain template, or RTF when
    /// `richText`). Optional fields keep hand-editing friendly.
    struct Entry: Codable, Equatable {
        var name: String
        var keyword: String?
        var text: String
        var collection: String?
        var description: String?
        var autoExpand: Bool?
        var richText: Bool?
    }
    struct CollectionEntry: Codable, Equatable {
        var name: String
        var prefix: String?
        var suffix: String?
    }
    /// `version` / `collections` are optional so a hand-edited file may omit them
    /// (synthesized `Decodable` throws on a missing non-optional key — defaults are
    /// not consulted when decoding). `snippets` is required.
    private struct Document: Codable {
        var version: Int?
        var collections: [CollectionEntry]?
        var snippets: [Entry]
    }

    // MARK: - Keyword sanitation

    /// A valid keyword carries no whitespace and no quote characters — both act as
    /// expansion delimiters (Raycast's rule). Returns the trimmed, delimiter-free
    /// keyword (possibly empty, which means "no auto-expand trigger").
    static func sanitizeKeyword(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && scalar != "\"" && scalar != "'"
        })
    }

    // MARK: - Read / search (runner UI + expander)

    /// All saved snippets, sorted by name.
    static func all() -> [SnippetHit] {
        loadEntries().map(hit(from:)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All collections, sorted by name.
    static func allCollections() -> [SnippetCollection] {
        loadCollections()
            .map { SnippetCollection(name: $0.name, prefix: $0.prefix ?? "", suffix: $0.suffix ?? "") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Snippets whose name / keyword / description contains `query`,
    /// case-insensitively. Empty query returns all. Name/keyword hits sort before
    /// description-only hits.
    static func search(_ query: String) -> [SnippetHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = all()
        guard !needle.isEmpty else { return items }
        let primary = items.filter {
            $0.name.lowercased().contains(needle) || $0.keyword.lowercased().contains(needle)
        }
        let secondary = items.filter {
            !($0.name.lowercased().contains(needle) || $0.keyword.lowercased().contains(needle))
                && $0.description.lowercased().contains(needle)
        }
        return primary + secondary
    }

    /// The snippet with the given (case-sensitive) name, or nil.
    static func byName(_ name: String) -> SnippetHit? {
        let key = name.trimmingCharacters(in: .whitespaces)
        return all().first { $0.name == key }
    }

    /// The snippet whose *effective* trigger (affixes applied) equals
    /// `effectiveKeyword`. Used by the matcher once it has identified a fired
    /// trigger. Case-sensitive (keywords are typed verbatim).
    static func byKeyword(_ effectiveKeyword: String) -> SnippetHit? {
        let collections = collectionAffixes()
        return all().first { hit in
            guard !hit.keyword.isEmpty else { return false }
            return effectiveTrigger(keyword: hit.keyword, collection: hit.collection,
                                    collections: collections) == effectiveKeyword
        }
    }

    /// Effective triggers for every snippet that has a keyword AND opts into
    /// auto-expansion, paired with the snippet name. Feeds `SnippetMatcher`.
    static func effectiveKeywords() -> [(trigger: String, id: String)] {
        let collections = collectionAffixes()
        return all().compactMap { hit in
            guard hit.autoExpand, !hit.keyword.isEmpty else { return nil }
            let trigger = effectiveTrigger(keyword: hit.keyword, collection: hit.collection,
                                           collections: collections)
            return trigger.isEmpty ? nil : (trigger, hit.name)
        }
    }

    /// `prefix + keyword + suffix` using the named collection's affixes (empty
    /// affixes when the collection is unknown / unset).
    static func effectiveTrigger(keyword: String, collection: String,
                                 collections: [String: (prefix: String, suffix: String)]) -> String {
        let affix = collections[collection]
        return (affix?.prefix ?? "") + keyword + (affix?.suffix ?? "")
    }

    // MARK: - Write (palette / Settings)

    /// Saves (or overwrites by name) a single snippet, then rewrites the file.
    static func save(_ hit: SnippetHit) {
        var entries = loadEntries()
        let entry = entry(from: hit)
        guard !entry.name.isEmpty, !entry.text.isEmpty else { return }
        if let idx = entries.firstIndex(where: { $0.name == entry.name }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        persist(entries: entries, collections: loadCollections())
    }

    /// Replaces the entire snippet set (used by the Settings config UI). Entries
    /// missing a name or text are dropped; collections are left untouched.
    static func replaceAll(_ items: [SnippetHit]) {
        let entries = items.map(entry(from:)).filter { !$0.name.isEmpty && !$0.text.isEmpty }
        persist(entries: entries, collections: loadCollections())
    }

    /// Replaces the entire collection set (used by the Settings config UI).
    static func replaceCollections(_ items: [SnippetCollection]) {
        let entries = items
            .map { CollectionEntry(name: $0.name.trimmingCharacters(in: .whitespaces),
                                   prefix: $0.prefix.isEmpty ? nil : $0.prefix,
                                   suffix: $0.suffix.isEmpty ? nil : $0.suffix) }
            .filter { !$0.name.isEmpty }
        persist(entries: loadEntries(), collections: entries)
    }

    /// Deletes a snippet by name (no-op if absent) and rewrites the file.
    static func remove(name: String) {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        var entries = loadEntries()
        let before = entries.count
        entries.removeAll { $0.name == key }
        guard entries.count != before else { return }
        persist(entries: entries, collections: loadCollections())
    }

    // MARK: - Import / export

    /// The current store as pretty JSON (the same shape as the on-disk file).
    static func exportJSON() -> String {
        encodeDocument(Document(version: 1, collections: loadCollections(), snippets: loadEntries())) ?? "{}"
    }

    /// Result of an import attempt.
    enum ImportResult: Equatable { case imported(Int), failed(String) }

    /// Merges snippets (upsert by name) and collections from a JSON document in the
    /// on-disk shape. Returns the number of snippets imported, or a failure.
    @discardableResult
    static func importJSON(_ json: String) -> ImportResult {
        guard let doc = decodeDocument(json) else { return .failed("invalid JSON") }
        var entries = loadEntries()
        for incoming in doc.snippets {
            let name = incoming.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !incoming.text.isEmpty else { continue }
            var merged = incoming
            merged.name = name
            merged.keyword = incoming.keyword.map(sanitizeKeyword)
            if let idx = entries.firstIndex(where: { $0.name == name }) {
                entries[idx] = merged
            } else {
                entries.append(merged)
            }
        }
        var collections = loadCollections()
        for c in (doc.collections ?? []) {
            let name = c.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let idx = collections.firstIndex(where: { $0.name == name }) {
                collections[idx] = c
            } else {
                collections.append(c)
            }
        }
        persist(entries: entries, collections: collections)
        return .imported(doc.snippets.count)
    }

    // MARK: - Disk sync

    /// Reconciles the on-disk file with UserDefaults. Call once at launch.
    static func bootstrap() {
        let onDisk = readFileRaw()
        let mirror = defaults.string(forKey: mirrorKey)

        if let onDisk, onDisk != mirror, let doc = decodeDocument(onDisk) {
            // External edit / import → the file is the source of truth: upsert into
            // UserDefaults so the extension + expander route the new entries.
            var entries = loadEntries()
            for incoming in doc.snippets where !incoming.name.isEmpty && !incoming.text.isEmpty {
                if let idx = entries.firstIndex(where: { $0.name == incoming.name }) {
                    entries[idx] = incoming
                } else {
                    entries.append(incoming)
                }
            }
            let docCollections = doc.collections ?? []
            persist(entries: entries, collections: docCollections.isEmpty ? loadCollections() : docCollections)
        } else {
            // No external change → UserDefaults wins; (re)write the file.
            persist(entries: loadEntries(), collections: loadCollections())
        }
    }

    // MARK: - Internals

    private static func hit(from e: Entry) -> SnippetHit {
        SnippetHit(name: e.name, keyword: e.keyword ?? "", text: e.text,
                   collection: e.collection ?? "", description: e.description ?? "",
                   autoExpand: e.autoExpand ?? true, richText: e.richText ?? false)
    }

    private static func entry(from hit: SnippetHit) -> Entry {
        let kw = sanitizeKeyword(hit.keyword)
        return Entry(
            name: hit.name.trimmingCharacters(in: .whitespaces),
            keyword: kw.isEmpty ? nil : kw,
            text: hit.text,
            collection: hit.collection.isEmpty ? nil : hit.collection,
            description: hit.description.isEmpty ? nil : hit.description,
            autoExpand: hit.autoExpand ? nil : false,  // default true; persist only the off case
            richText: hit.richText ? true : nil)       // default false; persist only the on case
    }

    /// Collection name → affixes, for trigger composition.
    private static func collectionAffixes() -> [String: (prefix: String, suffix: String)] {
        var out: [String: (prefix: String, suffix: String)] = [:]
        for c in loadCollections() {
            out[c.name] = (c.prefix ?? "", c.suffix ?? "")
        }
        return out
    }

    /// Writes both UserDefaults maps and the mirror file, and bumps `changeToken`.
    private static func persist(entries: [Entry], collections: [CollectionEntry]) {
        storeArray(entries, itemsKey)
        storeArray(collections, collectionsKey)
        writeFile(entries: entries, collections: collections)
        defaults.set(changeToken &+ 1, forKey: changeTokenKey)
    }

    private static func writeFile(entries: [Entry], collections: [CollectionEntry]) {
        let sorted = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let json = encodeDocument(Document(version: 1, collections: collections, snippets: sorted)) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            defaults.set(json, forKey: mirrorKey)
        } catch {
            NSLog("prosper: failed to write snippets.json: \(error)")
        }
    }

    private static func readFileRaw() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private static func encodeDocument(_ doc: Document) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(doc) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeDocument(_ json: String) -> Document? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }

    // MARK: - UserDefaults arrays (what the Lua extension reads)

    private static func loadEntries() -> [Entry] { loadArray(itemsKey) }
    private static func loadCollections() -> [CollectionEntry] { loadArray(collectionsKey) }

    private static func loadArray<T: Decodable>(_ key: String) -> [T] {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([T].self, from: data)
        else { return [] }
        return arr
    }

    private static func storeArray<T: Encodable>(_ arr: [T], _ key: String) {
        guard let data = try? JSONEncoder().encode(arr),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key)
    }
}
