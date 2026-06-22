import Foundation
import GRDB

/// Reads the user's existing browser search engines so they can be imported as
/// fallback providers, sparing them from retyping templates they already use.
///
/// Chromium browsers store keyword search engines in a `Web Data` SQLite file
/// (`keywords` table, `url` column carrying a `{searchTerms}` placeholder). Safari
/// exposes only its single default engine via a preference. Everything returns []
/// gracefully on any failure — a missing/locked/corrupt file never throws into UI.
enum BrowserSearchImporter {

    /// Discover providers from whichever browser is currently the default.
    static func providers(forDefaultBrowser bundleID: String) -> [FallbackProvider] {
        if let vendor = chromiumVendorPath(for: bundleID) {
            return chromiumProviders(appSupportSubpath: vendor)
        }
        if bundleID == "com.apple.Safari" {
            return safariProvider().map { [$0] } ?? []
        }
        // Firefox/Zen store engines in `search.json.mozlz4`, which needs a mozLz4
        // decompress step. ponytail: add Firefox search import when a user asks.
        return []
    }

    // MARK: Chromium

    /// Application-Support subpath of the Chromium profile dir for a known browser
    /// bundle id, or nil for non-Chromium browsers. We read the `Default` profile.
    private static func chromiumVendorPath(for bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome":            return "Google/Chrome/Default"
        case "com.google.Chrome.beta":       return "Google/Chrome Beta/Default"
        case "com.brave.Browser":            return "BraveSoftware/Brave-Browser/Default"
        case "com.microsoft.edgemac":        return "Microsoft Edge/Default"
        case "company.thebrowser.Browser":   return "Arc/User Data/Default"
        case "com.vivaldi.Vivaldi":          return "Vivaldi/Default"
        default:                             return nil
        }
    }

    /// Parse the `keywords` table of a Chromium `Web Data` SQLite file. The file may
    /// be locked / WAL-journaled by a running browser, so we copy it to a temp path
    /// and open that read-only.
    private static func chromiumProviders(appSupportSubpath: String) -> [FallbackProvider] {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return [] }
        let webData = appSupport.appendingPathComponent(appSupportSubpath)
            .appendingPathComponent("Web Data")
        guard FileManager.default.fileExists(atPath: webData.path) else { return [] }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-webdata-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: temp.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: temp.path + "-shm"))
        }
        do {
            try FileManager.default.copyItem(at: webData, to: temp)
            // A running browser keeps recent engine edits in the WAL; copy it too so we
            // don't read only the last checkpoint. Skip -shm — it's a regenerable index
            // into the WAL, and copying a stale one can make the open reject the snapshot.
            let wal = URL(fileURLWithPath: webData.path + "-wal")
            if FileManager.default.fileExists(atPath: wal.path) {
                try? FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: temp.path + "-wal"))
            }
        } catch {
            return []
        }

        // Open the private COPY read-write (NEVER the browser's live file). Read-write
        // lets SQLite fold the WAL into the copy and rebuild -shm itself — a read-only
        // open can't when -shm is absent, so this keeps recent edits visible and stops a
        // missing/stale -shm from failing the open. The copy is deleted in `defer`.
        guard let queue = try? DatabaseQueue(path: temp.path) else { return [] }

        // Bound the read so a browser with thousands of keyword rows can't materialize an
        // unbounded array before the store's `maxProviders` cap applies downstream.
        let rows: [(name: String, url: String)] = (try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT short_name, url FROM keywords
                WHERE url LIKE '%{searchTerms}%'
                LIMIT 256
                """).compactMap { row -> (String, String)? in
                // 256 = 4× the store's maxProviders (64); headroom for dedupe/scheme
                // drop, and the store clamps the final list anyway. Inlined because
                // maxProviders is @MainActor-isolated and this read runs off-main.
                guard let name: String = row["short_name"], let url: String = row["url"] else { return nil }
                return (name, url)
            }
        }) ?? []

        var seen = Set<String>()
        var out: [FallbackProvider] = []
        for (name, url) in rows {
            // Only http(s) templates — Chromium also stores opensearch/extension
            // engines we cannot open as a plain link.
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            let template = url.replacingOccurrences(of: "{searchTerms}", with: "{query}")
            let id = slug(name)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(FallbackProvider(id: id, name: name, urlTemplate: template,
                                        enabled: true, titleTemplate: nil))
        }
        return out
    }

    // MARK: Safari

    /// Safari only has one default engine, named by a preference identifier. Map the
    /// known identifiers to their search template. Returns nil when unknown/unset.
    private static func safariProvider() -> FallbackProvider? {
        let suite = UserDefaults(suiteName: "com.apple.Safari")
        guard let id = suite?.string(forKey: "SearchProviderIdentifier") else { return nil }
        let table: [String: (String, String)] = [
            "com.google.www":          ("Google",     "https://www.google.com/search?q={query}"),
            "com.bing.www":            ("Bing",       "https://www.bing.com/search?q={query}"),
            "com.yahoo.www":           ("Yahoo",      "https://search.yahoo.com/search?p={query}"),
            "com.duckduckgo":          ("DuckDuckGo", "https://duckduckgo.com/?q={query}"),
            "com.ecosia.www":          ("Ecosia",     "https://www.ecosia.org/search?q={query}"),
        ]
        guard let (name, template) = table[id] else { return nil }
        return FallbackProvider(id: slug(name), name: name, urlTemplate: template,
                                enabled: true, titleTemplate: nil)
    }

    // MARK: Helpers

    /// Lowercase, non-alphanumerics collapsed to "-", a stable id for dedupe.
    private static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
