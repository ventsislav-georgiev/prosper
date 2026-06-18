import Foundation

/// Spotlight-backed file finder (`f <name>`), the Alfred/Raycast "find a file and
/// act on it" capability. Wraps **`NSMetadataQuery`** with a structured query —
/// name tokens, `kind:`/`ext:`/`in:` filters, optional content search — and ranks
/// the matches by name-match quality blended with **frecency** (FrecencyStore) and
/// recency. `NSMetadataQuery` is the right backend (over `mdfind`): one query
/// returns each item's metadata (display name, kind, size, modification date,
/// content-type tree) directly — no subprocess, no per-file `stat` — honors
/// Spotlight scope constants, and can stream **live** result updates for a future
/// incremental-results enhancement. Read-only — it never touches the matched files.
enum FileSearchEngine {

    /// Default search scope: the user's home folder (Alfred's default), keeping
    /// results off the noisy system / cache trees. Overridden by an `in:` filter.
    static var defaultScope: String { NSHomeDirectory() }

    static let maxResults = 15
    static let maxCandidates = 250
    /// Wall-clock ceiling for one Spotlight gather; resumes with whatever was found.
    static let timeout: TimeInterval = 4.0

    // MARK: - Query model

    /// A structured file search. The Lua extension parses the typed text into these
    /// fields (`kind:`, `ext:`, `in:` tokens) and hands them over as JSON; heavy
    /// lifting stays here in native code.
    struct FileQuery: Equatable {
        var name: String = ""
        var kinds: [String] = []     // friendly kind names: image, pdf, folder, …
        var exts: [String] = []      // file extensions: pdf, png, …
        var scope: String = defaultScope
        var content: Bool = false    // match file contents, not just the name
        var limit: Int = maxResults

        /// Decodes the options object the Lua `host.files.search{…}` wrapper sends.
        static func decode(json: String) -> FileQuery {
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return FileQuery() }
            var q = FileQuery()
            q.name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            q.kinds = stringList(obj["kind"]) + stringList(obj["kinds"])
            q.exts = stringList(obj["ext"]) + stringList(obj["exts"])
            if let scope = obj["in"] as? String, !scope.isEmpty {
                q.scope = (scope as NSString).expandingTildeInPath
            }
            q.content = (obj["content"] as? Bool) ?? false
            if let lim = obj["limit"] as? Int { q.limit = min(max(lim, 1), maxResults) }
            else if let lim = obj["limit"] as? Double { q.limit = min(max(Int(lim), 1), maxResults) }
            return q
        }

        /// Accepts a string or an array of strings (so `kind = "pdf"` and
        /// `kind = {"pdf","image"}` both decode), lowercased + de-blanked.
        private static func stringList(_ v: Any?) -> [String] {
            if let s = v as? String { return s.isEmpty ? [] : [s.lowercased()] }
            if let a = v as? [Any] { return a.compactMap { ($0 as? String)?.lowercased() }.filter { !$0.isEmpty } }
            return []
        }
    }

    /// One ranked result, enriched with native metadata for display + actions.
    struct FileHit: Equatable {
        let name: String
        let path: String
        let display: String   // path with the home folder abbreviated to `~`
        let isDir: Bool
        let kind: String      // localized kind (e.g. "PDF document")
        let size: Int64
        let modified: TimeInterval

        /// JSON object the Lua layer decodes (via host.json) into a list item.
        var jsonObject: [String: Any] {
            ["name": name, "path": path, "display": display,
             "isDir": isDir, "kind": kind, "size": size, "modified": modified]
        }
    }

    /// A candidate paired with its enrichment, ranked without further I/O.
    struct Candidate: Equatable {
        let hit: FileHit
        var name: String { hit.name }
        var modified: TimeInterval { hit.modified }
    }

    // MARK: - Search entry point

    /// Ranked hits for `q`, encoded as a JSON array string `[{…FileHit…}]`. Empty
    /// (`"[]"`) for a blank/too-short name with no filters, or no matches.
    static func searchJSON(_ q: FileQuery,
                           index: FileIndex = SpotlightFileIndex(),
                           frecency: FrecencyStore = .shared,
                           now: TimeInterval = Date().timeIntervalSince1970) async -> String {
        let hits = await search(q, index: index, frecency: frecency, now: now)
        guard let data = try? JSONSerialization.data(withJSONObject: hits.map(\.jsonObject)),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Ranked hits for `q`. Gathers candidates from `index` (Spotlight in
    /// production; an in-memory fake under test), then ranks by name tier +
    /// frecency + recency. A bare name under two chars floods the index, so it is
    /// allowed only when a `kind:`/`ext:` filter narrows the search.
    static func search(_ q: FileQuery,
                       index: FileIndex = SpotlightFileIndex(),
                       frecency: FrecencyStore = .shared,
                       now: TimeInterval = Date().timeIntervalSince1970) async -> [FileHit] {
        let bareName = q.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bareName.count >= 2 || !q.kinds.isEmpty || !q.exts.isEmpty else { return [] }

        let candidates = await index.gather(q, limit: maxCandidates)
        let boosts = frecency.boosts(for: candidates.map(\.hit.path), now: now)
        return rank(candidates, query: bareName, boosts: boosts, limit: q.limit).map(\.hit)
    }

    // MARK: - Ranking (pure → unit-testable)

    /// Ranks `candidates` against the typed `name`, blending frecency `boosts`.
    /// Sort key (high → low): name-match **tier**, then frecency, then shorter
    /// name, then most-recently modified, then alphabetical. Trimmed to `limit`.
    static func rank(_ candidates: [Candidate], query: String,
                     boosts: [String: Double], limit: Int = maxResults) -> [Candidate] {
        let ql = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ranked = candidates.sorted { a, b in
            let ta = tier(name: a.name, query: ql), tb = tier(name: b.name, query: ql)
            if ta != tb { return ta > tb }
            let fa = boosts[a.hit.path] ?? 0, fb = boosts[b.hit.path] ?? 0
            if fa != fb { return fa > fb }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.name < b.name
        }
        return Array(ranked.prefix(limit))
    }

    /// Coarse name-match tier (4 → 0). A blank query (filter-only search) gives
    /// every candidate the same tier so frecency/recency drive the order.
    static func tier(name: String, query ql: String) -> Int {
        guard !ql.isEmpty else { return 0 }
        let nl = name.lowercased()
        if nl == ql { return 4 }
        if nl.hasPrefix(ql) { return 3 }
        if nl.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .contains(where: { $0.hasPrefix(ql) }) { return 2 }
        if nl.contains(ql) { return 1 }
        return 0  // Spotlight matched on path/content, not the name
    }

    // MARK: - Spotlight predicate + scopes (pure → unit-testable)

    /// Friendly `kind:` names → Spotlight content-type-tree UTIs. Unknown kinds
    /// fall through to being treated as an extension (see `buildPredicate`).
    static let kindUTI: [String: String] = [
        "image": "public.image",
        "photo": "public.image",
        "audio": "public.audio",
        "music": "public.audio",
        "video": "public.movie",
        "movie": "public.movie",
        "pdf": "com.adobe.pdf",
        "folder": "public.folder",
        "directory": "public.folder",
        "app": "com.apple.application-bundle",
        "application": "com.apple.application-bundle",
        "archive": "public.archive",
        "zip": "public.archive",
        "text": "public.text",
        "code": "public.source-code",
        "source": "public.source-code",
        "doc": "public.composite-content",
        "document": "public.composite-content",
        "presentation": "public.presentation",
        "spreadsheet": "public.spreadsheet",
    ]

    /// Builds the `NSMetadataQuery` predicate for `q`, or nil when there's nothing
    /// to search for. Name words are AND-ed (case/diacritic-insensitive `LIKE[cd]`
    /// over the display name, also the text content when `content`); `kind:` values
    /// are OR-ed (content-type tree); `ext:` values are OR-ed (filename suffix); an
    /// unknown `kind:` becomes an extension match.
    static func buildPredicate(_ q: FileQuery) -> NSPredicate? {
        var groups: [NSPredicate] = []

        for w in q.name.split(whereSeparator: { $0 == " " }).map(String.init) {
            let like = "*\(w)*"
            if q.content {
                groups.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "%K LIKE[cd] %@", "kMDItemDisplayName", like),
                    NSPredicate(format: "%K LIKE[cd] %@", "kMDItemTextContent", like),
                ]))
            } else {
                groups.append(NSPredicate(format: "%K LIKE[cd] %@", "kMDItemDisplayName", like))
            }
        }

        var kindPreds: [NSPredicate] = []
        var extFromKinds: [String] = []
        for k in q.kinds {
            if let uti = kindUTI[k] {
                kindPreds.append(NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", uti))
            } else {
                extFromKinds.append(k)
            }
        }
        if let group = orGroup(kindPreds) { groups.append(group) }

        let exts = (q.exts + extFromKinds).map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        let extPreds = exts.map { NSPredicate(format: "%K LIKE[cd] %@", "kMDItemFSName", "*.\($0)") }
        if let group = orGroup(extPreds) { groups.append(group) }

        guard !groups.isEmpty else { return nil }
        return groups.count == 1 ? groups[0] : NSCompoundPredicate(andPredicateWithSubpredicates: groups)
    }

    /// Combines predicates with OR (nil if empty, the lone predicate if one).
    private static func orGroup(_ preds: [NSPredicate]) -> NSPredicate? {
        guard !preds.isEmpty else { return nil }
        return preds.count == 1 ? preds[0] : NSCompoundPredicate(orPredicateWithSubpredicates: preds)
    }

    /// Spotlight search scopes for `q` — the (tilde-expanded) `in:` path, or the
    /// home folder by default. `NSMetadataQuery` accepts directory path strings.
    static func searchScopes(_ q: FileQuery) -> [String] { [q.scope] }

    /// Replaces a leading `home` with `~` for compact display.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    // MARK: - Filter semantics (pure → the single source of truth)

    /// A file as the index sees it — the metadata the filters operate on. Production
    /// reads these from `NSMetadataItem`; tests supply them directly.
    struct IndexedFile: Equatable {
        var path: String
        var contentTypeTree: [String] = []  // UTIs, e.g. ["com.adobe.pdf", "public.data"]
        var textContent: String = ""
        var isDir: Bool = false
        var kind: String = "File"           // localized kind for display
        var size: Int64 = 0
        var modified: TimeInterval = 0

        var name: String { (path as NSString).lastPathComponent }
        var ext: String { (path as NSString).pathExtension.lowercased() }

        /// The ranked candidate this file becomes (home-relative display path).
        func candidate(home: String) -> Candidate {
            Candidate(hit: FileHit(
                name: name, path: path, display: FileSearchEngine.abbreviate(path, home: home),
                isDir: isDir, kind: kind, size: size, modified: modified))
        }
    }

    /// True if `file` satisfies `q`'s name + kind + ext + content filters. This is
    /// the single source of truth for filter semantics; `buildPredicate` is its
    /// `NSMetadataQuery` translation (name words AND-ed; kinds OR-ed; exts OR-ed;
    /// unknown kind → extension; the groups AND together). Pure → testable, and the
    /// fake `FileIndex` evaluates exactly this.
    static func matches(_ file: IndexedFile, _ q: FileQuery) -> Bool {
        let nameL = file.name.lowercased()
        let contentL = file.textContent.lowercased()
        for w in q.name.split(whereSeparator: { $0 == " " }).map({ String($0).lowercased() }) {
            let hit = nameL.contains(w) || (q.content && contentL.contains(w))
            if !hit { return false }
        }

        var kindUTIs: [String] = []
        var extFromKinds: [String] = []
        for k in q.kinds {
            if let uti = kindUTI[k] { kindUTIs.append(uti) } else { extFromKinds.append(k) }
        }
        if !kindUTIs.isEmpty,
           !kindUTIs.contains(where: { file.contentTypeTree.contains($0) }) {
            return false
        }

        // Lowercased to mirror the production predicate's case-insensitive match.
        let exts = (q.exts + extFromKinds).map {
            ($0.hasPrefix(".") ? String($0.dropFirst()) : $0).lowercased()
        }
        if !exts.isEmpty, !exts.contains(file.ext) { return false }

        return true
    }
}

/// The source of file-search candidates. Abstracted so the production Spotlight
/// query can be swapped for an in-memory fake in tests (mocked file system).
protocol FileIndex: Sendable {
    func gather(_ query: FileSearchEngine.FileQuery, limit: Int) async -> [FileSearchEngine.Candidate]
}

/// Production `FileIndex`: builds the `NSMetadataQuery` predicate + scopes and runs
/// the Spotlight gather (`FileSpotlight`).
struct SpotlightFileIndex: FileIndex {
    func gather(_ q: FileSearchEngine.FileQuery, limit: Int) async -> [FileSearchEngine.Candidate] {
        guard let predicate = FileSearchEngine.buildPredicate(q) else { return [] }
        return await FileSpotlight.gather(
            predicate: predicate, scopes: FileSearchEngine.searchScopes(q),
            limit: limit, timeout: FileSearchEngine.timeout)
    }
}

/// Runs an `NSMetadataQuery` to gathering completion and maps its items to
/// `FileSearchEngine.Candidate`s. `NSMetadataQuery` is run-loop driven and delivers
/// its notifications on the thread that started it, so the query lives on the main
/// actor; the calling extension worker awaits the result off-main (the host bridge
/// blocks the worker, never main, so the run loop stays free to gather).
@MainActor
enum FileSpotlight {

    /// Gathers up to `limit` candidates matching `predicate` within `scopes`,
    /// resuming with whatever was found by `timeout` if the gather runs long.
    static func gather(predicate: NSPredicate, scopes: [String],
                       limit: Int, timeout: TimeInterval) async -> [FileSearchEngine.Candidate] {
        let query = NSMetadataQuery()
        query.predicate = predicate
        // NSMetadataQuery takes directory URLs (or scope constants) — map the path
        // scopes to file URLs rather than passing raw strings.
        query.searchScopes = scopes.map { URL(fileURLWithPath: $0) }
        // Recent-first so the capped prefix we read favours fresh files; final order
        // is decided by FileSearchEngine.rank (name tier + frecency + recency).
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        let home = NSHomeDirectory()

        return await withCheckedContinuation { (cont: CheckedContinuation<[FileSearchEngine.Candidate], Never>) in
            // A @MainActor coordinator owns the mutable gather state so the run-loop
            // callbacks (NotificationCenter / asyncAfter — @Sendable) can call back in
            // without sending non-Sendable captures across actors (Swift 6 strict).
            // ponytail: coord + its query/observer/state live only on main (callbacks
            // fire on .main queue / main run loop), but the @Sendable run-loop closures
            // below can't prove it to region isolation. main-confined → opt out.
            nonisolated(unsafe) let coord = GatherCoordinator(query: query, limit: limit, home: home, cont: cont)
            coord.observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in MainActor.assumeIsolated { coord.finish() } }
            // Timeout safety net: resume with whatever has been gathered so far.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { coord.finish() }
            }
            if !query.start() { coord.finish() }
        }
    }

    /// Owns the mutable state of one `gather` so the run-loop callbacks can resume
    /// the continuation without sending non-Sendable captures across actor contexts.
    @MainActor
    private final class GatherCoordinator {
        private let query: NSMetadataQuery
        private let limit: Int
        private let home: String
        private let cont: CheckedContinuation<[FileSearchEngine.Candidate], Never>
        var observer: NSObjectProtocol?
        private var resumed = false

        init(query: NSMetadataQuery, limit: Int, home: String,
             cont: CheckedContinuation<[FileSearchEngine.Candidate], Never>) {
            self.query = query
            self.limit = limit
            self.home = home
            self.cont = cont
        }

        func finish() {
            guard !resumed else { return }
            resumed = true
            query.disableUpdates()  // freeze the result set before reading
            let n = min(query.resultCount, limit)
            var cands: [FileSearchEngine.Candidate] = []
            cands.reserveCapacity(n)
            for i in 0..<n {
                guard let item = query.result(at: i) as? NSMetadataItem,
                      let c = FileSpotlight.candidate(from: item, home: home) else { continue }
                cands.append(c)
            }
            query.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            cont.resume(returning: cands)
        }
    }

    /// Maps an `NSMetadataItem` to a candidate, reading its metadata attributes
    /// directly (no extra filesystem access). `nonisolated`: touches no main-actor
    /// state, so the run-loop `finish()` closure can map results without hopping actor.
    nonisolated private static func candidate(from item: NSMetadataItem, home: String) -> FileSearchEngine.Candidate? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
            ?? (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
            ?? (path as NSString).lastPathComponent
        let kind = (item.value(forAttribute: NSMetadataItemKindKey) as? String) ?? "File"
        let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
        let modified = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)?
            .timeIntervalSince1970 ?? 0
        let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        let isDir = tree.contains("public.folder")
        let hit = FileSearchEngine.FileHit(
            name: name, path: path, display: FileSearchEngine.abbreviate(path, home: home),
            isDir: isDir, kind: kind, size: size, modified: modified)
        return FileSearchEngine.Candidate(hit: hit)
    }
}
