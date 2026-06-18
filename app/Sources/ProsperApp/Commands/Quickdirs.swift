import AppKit
import Foundation

/// One configured quickdir: a root directory whose immediate subdirectories are
/// browsed from the runner, with its own activation prefix and an action template
/// run against the selected directory.
///
/// `action` is a shell command (e.g. `code {path}`) OR a URL (contains `://`,
/// e.g. `https://example.com/?repo={name}`) — substituting `{path}` (full path),
/// `{name}` (directory name), and `{query}` (the trailing filter text). URL
/// targets are opened via `NSWorkspace`; everything else runs through the shell.
struct QuickdirConfig: Codable, Equatable, Identifiable, Sendable {
    var name: String        // display + lookup key, e.g. "projects"
    var path: String        // root dir, e.g. "~/projects"
    var prefix: String      // runner mode trigger letters, e.g. "p" (no trailing space)
    var action: String      // shell command or URL template; {path} {name} {query}
    var actionLabel: String // action-bar verb, e.g. "Open in VSCode"

    var id: String { name }
}

/// One browsable subdirectory surfaced to the runner.
struct QuickdirHit: Sendable, Equatable, Identifiable {
    let configName: String  // owning quickdir
    let name: String        // subdirectory name
    let path: String        // full expanded path
    let actionLabel: String // verb shown in the action bar

    var id: String { configName + "/" + name }
}

/// Owns the quickdirs configuration. Storage lives in the SAME namespaced
/// `host.prefs` store the Lua `quickdirs` extension reads (UserDefaults key
/// `ext.com.prosper.quickdirs.dirs`, a JSON array of `QuickdirConfig`), so the
/// native config UI / runner and the extension share one source of truth.
///
/// Mirrored to a human-editable file at `~/.config/prosper/quickdirs.json` for
/// export / version-control / bulk-import, reconciled at launch (mirrors the
/// `QuicklinkStore` design).
enum QuickdirStore {
    static let extensionID = "com.prosper.quickdirs"
    /// The single pref key the Lua extension decodes via `host.prefs.get("dirs")`.
    private static var dirsKey: String { "ext.\(extensionID).dirs" }
    private static var mirrorKey: String { "ext.\(extensionID).diskMirror" }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/quickdirs.json", isDirectory: false)
    }

    private struct Document: Codable {
        var version: Int = 1
        var quickdirs: [QuickdirConfig]
    }

    // MARK: - Read / write

    /// All configured quickdirs, in saved order.
    static func all() -> [QuickdirConfig] {
        guard let raw = UserDefaults.standard.string(forKey: dirsKey),
              let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([QuickdirConfig].self, from: data)
        else { return [] }
        return items
    }

    /// Replace the whole set (used by the config UI), persisting to prefs + file.
    static func replaceAll(_ items: [QuickdirConfig]) {
        let cleaned = items.map { sanitize($0) }
        store(cleaned)
        writeFile(cleaned)
    }

    /// Upsert by `name` (renaming removes the old key). Used by `qd add`.
    static func save(_ config: QuickdirConfig) {
        let c = sanitize(config)
        guard !c.name.isEmpty, !c.path.isEmpty else { return }
        var items = all().filter { $0.name.caseInsensitiveCompare(c.name) != .orderedSame }
        items.append(c)
        items.sort { $0.name.lowercased() < $1.name.lowercased() }
        store(items)
        writeFile(items)
    }

    /// Remove by name (no-op if absent).
    static func remove(name: String) {
        let key = name.trimmingCharacters(in: .whitespaces)
        let items = all().filter { $0.name.caseInsensitiveCompare(key) != .orderedSame }
        store(items)
        writeFile(items)
    }

    private static func sanitize(_ c: QuickdirConfig) -> QuickdirConfig {
        QuickdirConfig(
            name: c.name.trimmingCharacters(in: .whitespaces),
            path: c.path.trimmingCharacters(in: .whitespaces),
            prefix: c.prefix.trimmingCharacters(in: .whitespaces),
            action: c.action.trimmingCharacters(in: .whitespacesAndNewlines),
            actionLabel: c.actionLabel.trimmingCharacters(in: .whitespaces))
    }

    private static func store(_ items: [QuickdirConfig]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(items),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: dirsKey)
    }

    // MARK: - Lookup / listing

    /// Resolve a typed token (a quickdir's name OR its prefix, case-insensitive)
    /// to its config. Prefix matches win over name matches.
    static func config(forToken token: String) -> QuickdirConfig? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let items = all()
        return items.first { $0.prefix.lowercased() == t }
            ?? items.first { $0.name.lowercased() == t }
    }

    static func config(named name: String) -> QuickdirConfig? {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Immediate subdirectories of a quickdir's root, filtered (case-insensitive
    /// contains) by `filter`, sorted by name.
    static func listing(config: QuickdirConfig, filter: String) -> [QuickdirHit] {
        let expanded = (config.path as NSString).expandingTildeInPath
        guard !expanded.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: expanded),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.compactMap { url -> QuickdirHit? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let n = url.lastPathComponent
            if !needle.isEmpty, !n.lowercased().contains(needle) { return nil }
            return QuickdirHit(configName: config.name, name: n, path: url.path,
                               actionLabel: config.actionLabel.isEmpty ? "Open" : config.actionLabel)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Action

    /// Substitute `{path}` / `{name}` / `{query}` (any case) in the action
    /// template, URL-encoding when the action is a URL.
    static func resolvedAction(_ config: QuickdirConfig, dirPath: String, dirName: String, query: String) -> String {
        let isURL = config.action.contains("://")
        func enc(_ s: String) -> String { isURL ? urlEncode(s) : s }
        var out = config.action
        let map: [String: String] = [
            "{path}": enc(dirPath), "{Path}": enc(dirPath),
            "{name}": enc(dirName), "{Name}": enc(dirName),
            "{query}": enc(query),  "{Query}": enc(query),
        ]
        for (token, value) in map { out = out.replacingOccurrences(of: token, with: value) }
        return out
    }

    /// Run a quickdir's action against the selected directory: open URLs through
    /// `NSWorkspace`, otherwise run the shell command on a background queue.
    @MainActor
    static func run(hit: QuickdirHit, query: String) {
        guard let config = config(named: hit.configName) else { return }
        // No action configured → reveal the directory in Finder.
        guard !config.action.isEmpty else {
            NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
            return
        }
        let resolved = resolvedAction(config, dirPath: hit.path, dirName: hit.name, query: query)
        guard !resolved.isEmpty else { return }
        if config.action.contains("://") {
            if let url = URL(string: resolved) { NSWorkspace.shared.open(url) }
        } else {
            Task.detached { _ = await ShellRunner.run(resolved) }
        }
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Dynamic mode triggers

    /// One activation prefix per configured quickdir that has a non-empty prefix,
    /// each locking the runner into that quickdir's browse listing. Fed to
    /// `ExtensionRegistry.dynamicModeProvider`.
    @MainActor
    static func modeSpecs() -> [ExtensionRegistry.ModeTriggerSpec] {
        all().compactMap { cfg in
            let p = cfg.prefix.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            return ExtensionRegistry.ModeTriggerSpec(
                prefix: p + " ",
                commandID: "quickdirs.run",
                title: cfg.name,
                icon: "folder",
                arg: cfg.name)
        }
    }

    // MARK: - Disk sync

    /// Reconcile the on-disk file with prefs. Call once at launch. The file wins
    /// when it changed externally since we last wrote it; otherwise prefs win.
    static func bootstrap() {
        let onDisk = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mirror = UserDefaults.standard.string(forKey: mirrorKey)
        if let onDisk, !onDisk.isEmpty, onDisk != mirror,
           let data = onDisk.data(using: .utf8),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            let items = doc.quickdirs.map { sanitize($0) }.filter { !$0.name.isEmpty && !$0.path.isEmpty }
            store(items)
            writeFile(items)
        } else {
            writeFile(all())
        }
    }

    private static func writeFile(_ items: [QuickdirConfig]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Document(quickdirs: items)),
              let json = String(data: data, encoding: .utf8) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? json.write(to: fileURL, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(json, forKey: mirrorKey)
    }
}
