import Foundation

/// One web-search provider shown as a low-priority "fallback" row in the runner
/// when the query has no confident local match (Alfred/Raycast "default results").
/// `urlTemplate` carries a `{query}` placeholder substituted with the percent-
/// encoded query at open time; `titleTemplate` (optional) overrides the row label.
struct FallbackProvider: Codable, Equatable {
    var id: String          // stable slug, e.g. "google"
    var name: String        // display name, e.g. "Google"
    var urlTemplate: String // "https://www.google.com/search?q={query}"
    var enabled: Bool
    var titleTemplate: String?  // optional; default "Search {name} for ‘{query}’"
}

/// Native source of truth for fallback web-search providers + the append/empty-only
/// mode. UserDefaults-backed (mirrors the per-extension prefs discipline) so the
/// per-keystroke `rows` hot path reads it synchronously on the main actor without
/// any Lua round trip — the Lua extension only edits it via the `host.fallback.*`
/// API. Providers are cached in memory and invalidated on write.
@MainActor
final class FallbackSearchStore {
    static let shared = FallbackSearchStore()

    /// UserDefaults keys. Namespaced under `fallback.` like the other native stores.
    private enum Key {
        static let providers = "fallback.providers"
        static let appendMode = "fallback.appendMode"
    }

    /// Shipped defaults, seeded on first run. Google + Perplexity + Wikipedia +
    /// Amazon — the same starter set Alfred/Raycast ship.
    static let seeded: [FallbackProvider] = [
        FallbackProvider(id: "google", name: "Google",
                         urlTemplate: "https://www.google.com/search?q={query}", enabled: true,
                         titleTemplate: nil),
        FallbackProvider(id: "perplexity", name: "Perplexity",
                         urlTemplate: "https://www.perplexity.ai/search?q={query}", enabled: true,
                         titleTemplate: nil),
        FallbackProvider(id: "wikipedia", name: "Wikipedia",
                         urlTemplate: "https://en.wikipedia.org/w/index.php?search={query}", enabled: true,
                         titleTemplate: nil),
        FallbackProvider(id: "amazon", name: "Amazon",
                         urlTemplate: "https://www.amazon.com/s?k={query}", enabled: true,
                         titleTemplate: nil),
    ]

    private let defaults: UserDefaults
    private var cached: [FallbackProvider]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Providers

    var providers: [FallbackProvider] {
        get {
            if let cached { return cached }
            guard let data = defaults.data(forKey: Key.providers) else {
                // First run: seed and persist so the settings UI shows them too.
                persist(Self.seeded)
                return Self.seeded
            }
            let decoded = (try? JSONDecoder().decode([FallbackProvider].self, from: data)) ?? Self.seeded
            cached = decoded   // cache even the seed fallback, so corrupt JSON isn't re-decoded every read
            return decoded
        }
        set { persist(newValue) }
    }

    private func persist(_ list: [FallbackProvider]) {
        // Every write goes through `sanitized` — the choke point that keeps garbage
        // (empty id/name, a template with no `{query}` slot, duplicate ids) out of the
        // store, whether it arrives from the seed, an import, or `host.fallback.save`
        // (a Lua → native trust boundary). Off the hot path: writes are rare.
        let clean = Self.sanitized(list)
        cached = clean
        if let data = try? JSONEncoder().encode(clean) {
            defaults.set(data, forKey: Key.providers)
        }
    }

    /// Hard cap on persisted providers. The per-keystroke hot path filters+maps every
    /// enabled provider, so an unbounded list (a privileged ext could `save` thousands)
    /// would blow the row budget. 64 is far above any real use; excess is dropped.
    static let maxProviders = 64

    /// Drop unusable providers, dedupe by id (first wins), and clamp to `maxProviders`.
    /// A provider is usable only if it has an id, a name, an `http(s)` scheme, and a
    /// `{query}`/`{query+}` placeholder. The scheme guard matters because the row opens
    /// via `NSWorkspace` at the sink: it mirrors the importer's own http(s) filter so a
    /// `javascript:`/`file:`/custom-scheme template can't slip through the
    /// `host.fallback.save` Lua → native trust boundary and become a one-key launcher.
    static func sanitized(_ list: [FallbackProvider]) -> [FallbackProvider] {
        var seen = Set<String>()
        let clean = list.filter { p in
            !p.id.isEmpty && !p.name.isEmpty
                && (p.urlTemplate.hasPrefix("https://") || p.urlTemplate.hasPrefix("http://"))
                && (p.urlTemplate.contains("{query}") || p.urlTemplate.contains("{query+}"))
                && seen.insert(p.id).inserted
        }
        return Array(clean.prefix(Self.maxProviders))
    }

    // MARK: Mode

    /// true = always append fallbacks at the end (Alfred "smart append", default);
    /// false = only show them when the query has no real result.
    var appendMode: Bool {
        get {
            if defaults.object(forKey: Key.appendMode) == nil { return true }
            return defaults.bool(forKey: Key.appendMode)
        }
        set { defaults.set(newValue, forKey: Key.appendMode) }
    }

    // MARK: Template expansion

    /// Query chars left unencoded: `.urlQueryAllowed` minus the sub-delimiters that
    /// would inject params or be misread (a literal `+` decodes to a space). Built
    /// ONCE — rebuilding a mutated `CharacterSet` per call is the single most
    /// expensive op on the per-keystroke `expand` hot path (forces a bitmap copy).
    private static let allowedQueryChars: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?/#")
        return set
    }()

    /// Substitute `{query}` (percent-encoded for safe URL use) and `{query+}`
    /// (spaces → `+`, the rest percent-encoded) into `template`.
    func expand(template: String, query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.allowedQueryChars) ?? query
        // `{query+}`: classic web-form spacing. Encode first, then swap %20 → +.
        let plus = encoded.replacingOccurrences(of: "%20", with: "+")
        return template
            .replacingOccurrences(of: "{query+}", with: plus)
            .replacingOccurrences(of: "{query}", with: encoded)
    }

    /// Display label for a provider row. Uses `titleTemplate` when set, else the
    /// default "Search {name} for ‘{query}’". Substitutions are RAW (not encoded).
    func title(for provider: FallbackProvider, query: String) -> String {
        guard let template = provider.titleTemplate else {
            // Default-label fast path: one interpolation instead of two String scans
            // — this is on the per-keystroke row hot path (see `fallbackRows`).
            return "Search \(provider.name) for \u{2018}\(query)\u{2019}"
        }
        return template
            .replacingOccurrences(of: "{name}", with: provider.name)
            .replacingOccurrences(of: "{query}", with: query)
    }

    // MARK: JSON bridge (host.fallback.*)

    /// Providers as a JSON array string, for `host.fallback.list()`.
    func providersJSON() -> String {
        guard let data = try? JSONEncoder().encode(providers),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Replace the provider list from a JSON array string, for `host.fallback.save`.
    /// Invalid JSON is ignored (the store keeps its current value).
    func setProvidersJSON(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        if let list = try? JSONDecoder().decode([FallbackProvider].self, from: data) {
            providers = list
            return
        }
        // "Clear all" arrives from Lua as `{}` — an empty table encodes as a JSON object,
        // not `[]`, so the array decoder rejects it and (without this) deleting the last
        // provider would silently no-op and reappear on re-render. Treat an empty object
        // or empty payload as the empty list. Any other malformed JSON keeps the current
        // value (unchanged behavior).
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { providers = [] }
    }

    // MARK: Browser import

    /// Merge already-discovered providers into the store, deduping by `id`. Returns
    /// the number of NEW providers added. Cheap + main-actor only (no I/O) — the
    /// expensive discovery (`BrowserSearchImporter`) is done OFF the main thread by the
    /// caller so the import button can't jank the UI on a multi-MB browser DB.
    func merge(_ discovered: [FallbackProvider]) -> Int {
        var current = providers
        let known = Set(current.map { $0.id })
        var added = 0
        for p in discovered where !known.contains(p.id) {
            current.append(p)
            added += 1
        }
        if added > 0 { providers = current }
        return added
    }

    /// Convenience: discover from the default browser and merge. Runs the heavy
    /// discovery inline, so callers on the main actor should prefer doing the
    /// discovery off-main and calling `merge` (see `LiveExtensionHostServices`).
    func importFromDefaultBrowser() -> Int {
        merge(BrowserSearchImporter.providers(forDefaultBrowser: URLServices.defaultBrowserBundleID()))
    }
}
