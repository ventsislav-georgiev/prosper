import AppKit

/// Base64 encode/decode helper for the runner.
enum Base64Tool {
    /// `base64 <text>` → encoded; `unbase64 <text>` / `base64d <text>` → decoded.
    /// Returns (label, value) or nil if the prefix doesn't match.
    static func run(_ input: String) -> (label: String, value: String)? {
        let lower = input.lowercased()
        if let body = strip(input, prefixes: ["base64 ", "b64 "]) {
            return ("Base64 encode", Data(body.utf8).base64EncodedString())
        }
        if lower.hasPrefix("unbase64 ") || lower.hasPrefix("base64d ") || lower.hasPrefix("b64d ") {
            guard let body = strip(input, prefixes: ["unbase64 ", "base64d ", "b64d "]) else { return nil }
            guard let data = Data(base64Encoded: body.trimmingCharacters(in: .whitespaces)),
                  let text = String(data: data, encoding: .utf8) else {
                return ("Base64 decode", "(invalid base64)")
            }
            return ("Base64 decode", text)
        }
        return nil
    }

    private static func strip(_ s: String, prefixes: [String]) -> String? {
        let lower = s.lowercased()
        for p in prefixes where lower.hasPrefix(p) {
            return String(s.dropFirst(p.count))
        }
        return nil
    }
}

/// Launches an application by name (`o <app>`), mirroring Prosper v1's `o`.
///
/// Resolution goes through `AppIndex` (fuzzy name match + alias table), so human
/// names work — "System Preferences" resolves to the shipping "System Settings",
/// "calc" → Calculator, partial names → best match. Falls back to LaunchServices
/// bundle-id / exact-path lookup so an explicit bundle id still works.
enum AppLauncher {
    /// Returns the launched app's display name, or nil if not found.
    @MainActor
    static func launch(named raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Best fuzzy/alias match from the index.
        if let match = AppIndex.shared.best(name) {
            open(match.url)
            return match.name
        }

        // Fallbacks: bundle identifier, then exact ".app" path in standard dirs.
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: name) {
            open(url)
            return url.deletingPathExtension().lastPathComponent
        }
        let fm = FileManager.default
        for dir in AppIndex.searchDirs {
            let path = (dir as NSString).appendingPathComponent(name + ".app")
            if fm.fileExists(atPath: path) {
                open(URL(fileURLWithPath: path))
                return name
            }
        }
        return nil
    }

    /// Launches a resolved app bundle URL.
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Runs a shell command (`> <cmd>`) via `/bin/zsh -c` and captures output.
enum ShellRunner {
    static func run(_ command: String) async -> String {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // Login shell (`-l`): sources /etc/zprofile (path_helper adds
                // /usr/local/bin) and ~/.zprofile (e.g. `brew shellenv` adds
                // /opt/homebrew/bin). A GUI app launched by LaunchServices only
                // inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin, so without this a
                // bare `code`, `cursor`, `gh`, etc. is not found.
                process.arguments = ["-lc", cmd]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let out = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(returning: "error: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// `:` meta commands.
enum MetaCommand: String, Sendable {
    case quit
    case clearClipboard
    /// Opens the "Create Quicklink" dialog (Raycast parity). Reached via `ql new`
    /// / `ql create` in the runner; the UI handles it by presenting a form.
    case newQuicklink

    static func parse(_ input: String) -> MetaCommand? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case ":q", ":quit": return .quit
        case ":c", ":clear": return .clearClipboard
        case "ql new", "ql create", "ql add": return .newQuicklink
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .quit: return "Quit Prosper"
        case .clearClipboard: return "Clear clipboard history"
        case .newQuicklink: return "Create Quicklink"
        }
    }
}

/// Reads/writes the quicklinks the Lua `quicklinks` extension owns, so a native
/// "Create Quicklink" dialog and the `ql <name>` opener share one store.
///
/// The Lua side resolves `ql <name>` by reading a JSON `name → target` map via
/// `host.prefs` under the namespaced UserDefaults key `ext.<extensionID>.links`
/// (see `LiveExtensionHostServices.prefKey`). Descriptions are kept in a parallel
/// `descriptions` map so the Lua decoder (which expects string targets) is
/// unaffected.
///
/// On top of UserDefaults (the runtime store the extension reads), the quicklinks
/// are mirrored to a human-editable file at `~/.config/prosper/quicklinks.json`
/// so they can be exported, version-controlled, or bulk-imported from outside the
/// app. `bootstrap()` (called at launch) reconciles the two: if the file was
/// edited externally since we last wrote it, the file wins and is imported into
/// UserDefaults; otherwise UserDefaults wins and the file is rewritten (capturing
/// `ql add` / dialog edits made since the last launch).
/// One saved quicklink surfaced to the runner UI: lookup name, target (URL /
/// path / deeplink, may contain `{query}`), and an optional description.
struct QuicklinkHit: Sendable, Equatable, Identifiable {
    let name: String
    let target: String
    let description: String
    var id: String { name }
}

enum QuicklinkStore {
    private static let extensionID = "com.prosper.quicklinks"
    private static var linksKey: String { "ext.\(extensionID).links" }
    private static var descriptionsKey: String { "ext.\(extensionID).descriptions" }
    /// Snapshot of the JSON we last wrote to disk, used to detect external edits.
    private static var mirrorKey: String { "ext.\(extensionID).diskMirror" }

    /// Human-editable export/import file: `~/.config/prosper/quicklinks.json`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/quicklinks.json", isDirectory: false)
    }

    /// One on-disk entry. `description` is optional for friendlier hand-editing.
    struct Entry: Codable {
        let name: String
        let url: String
        var description: String?
    }
    private struct Document: Codable {
        var version: Int = 1
        var quicklinks: [Entry]
    }

    /// Saves (or overwrites) a quicklink. `name` is the lookup key used by
    /// `ql <name>`; `target` is a URL / path / deeplink (may contain `{query}`).
    static func save(name: String, target: String, description: String) {
        let key = name.trimmingCharacters(in: .whitespaces)
        let value = target.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return }

        var links = load(linksKey)
        links[key] = value
        store(links, linksKey)

        var descs = load(descriptionsKey)
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.isEmpty { descs[key] = nil } else { descs[key] = desc }
        store(descs, descriptionsKey)

        writeFile(from: links, descriptions: descs)
    }

    /// Replaces the entire set (used by the Settings config UI). Entries missing a
    /// name or target are dropped; a rename is just a different key here, so the
    /// old key disappears with no separate remove step.
    static func replaceAll(_ items: [QuicklinkHit]) {
        var links: [String: String] = [:]
        var descs: [String: String] = [:]
        for item in items {
            let key = item.name.trimmingCharacters(in: .whitespaces)
            let value = item.target.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            links[key] = value
            let d = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { descs[key] = d }
        }
        store(links, linksKey)
        store(descs, descriptionsKey)
        writeFile(from: links, descriptions: descs)
    }

    // MARK: - Read / search / delete (runner UI)

    /// All saved quicklinks, sorted by name.
    static func all() -> [QuicklinkHit] {
        let links = load(linksKey)
        let descs = load(descriptionsKey)
        return links.keys.sorted().map {
            QuicklinkHit(name: $0, target: links[$0] ?? "", description: descs[$0] ?? "")
        }
    }

    /// Quicklinks whose name (or description) contains `query`, case-insensitively.
    /// An empty query returns all. Name matches sort before description-only matches.
    static func search(_ query: String) -> [QuicklinkHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = all()
        guard !needle.isEmpty else { return items }
        let nameHits = items.filter { $0.name.lowercased().contains(needle) }
        let descHits = items.filter {
            !$0.name.lowercased().contains(needle) && $0.description.lowercased().contains(needle)
        }
        return nameHits + descHits
    }

    /// Quicklinks whose NAME contains `query`, case-insensitively. Used by the
    /// bare-name launcher path (no `ql` verb): name-only keeps it predictable and
    /// avoids description matches shadowing app search. Empty query → none.
    static func nameMatches(_ query: String) -> [QuicklinkHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return all().filter { $0.name.lowercased().contains(needle) }
    }

    /// Deletes a quicklink by name (no-op if absent) and rewrites the disk file.
    static func remove(name: String) {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        var links = load(linksKey)
        guard links[key] != nil else { return }
        links[key] = nil
        store(links, linksKey)
        var descs = load(descriptionsKey)
        descs[key] = nil
        store(descs, descriptionsKey)
        writeFile(from: links, descriptions: descs)
    }

    /// Substitutes `{query}` / `{Query}` / `{argument}` (any case) in a target with
    /// `query`, percent-encoding when the target is a URL. Mirrors the Lua opener.
    static func resolve(target: String, query: String) -> String {
        let isURL = target.contains("://")
        let value = isURL ? urlEncode(query) : query
        var out = target
        for token in ["{query}", "{Query}", "{argument}", "{Argument}"] {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        // `/` stays literal: RFC 3986 allows it in both path and query, and
        // path-style targets (github.com/{query} ← "owner/repo") break as %2F.
        allowed.insert(charactersIn: "-._~/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Disk sync

    /// Reconciles the on-disk file with UserDefaults. Call once at launch.
    static func bootstrap() {
        let onDisk = readFileRaw()
        let mirror = UserDefaults.standard.string(forKey: mirrorKey)

        if let onDisk, onDisk != mirror {
            // The file changed since we last wrote it → an external edit / import.
            // The file is the source of truth: merge its entries into UserDefaults
            // (upsert by name) so the extension can route them.
            if let doc = decode(onDisk) {
                var links = load(linksKey)
                var descs = load(descriptionsKey)
                for e in doc.quicklinks {
                    let name = e.name.trimmingCharacters(in: .whitespaces)
                    let url = e.url.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !url.isEmpty else { continue }
                    links[name] = url
                    let d = (e.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    descs[name] = d.isEmpty ? nil : d
                }
                store(links, linksKey)
                store(descs, descriptionsKey)
                writeFile(from: links, descriptions: descs)
            }
        } else {
            // No external change → UserDefaults wins; (re)write the file so it
            // reflects any `ql add` / dialog edits made since the last launch.
            writeFile(from: load(linksKey), descriptions: load(descriptionsKey))
        }
    }

    private static func writeFile(from links: [String: String], descriptions descs: [String: String]) {
        let entries = links.keys.sorted().map { name in
            Entry(name: name, url: links[name] ?? "",
                  description: descs[name].flatMap { $0.isEmpty ? nil : $0 })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Document(quicklinks: entries)),
              let json = String(data: data, encoding: .utf8) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(json, forKey: mirrorKey)
        } catch {
            NSLog("prosper: failed to write quicklinks.json: \(error)")
        }
    }

    private static func readFileRaw() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private static func decode(_ json: String) -> Document? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Document.self, from: data)
    }

    // MARK: - UserDefaults maps (what the Lua extension reads)

    private static func load(_ key: String) -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private static func store(_ map: [String: String], _ key: String) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: key)
    }
}
