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
///
/// Cancellation-aware (#833): `ExtensionHost.awaitSync` cancels the task on timeout, and
/// the cancel kills zsh's whole process group (TERM, SIGKILL after 1 s), so neither zsh
/// nor anything it started outlives the extension's timeout (unless the call opts out
/// with `keep_running`).
enum ShellRunner {
    /// Captured output stops at the cap. Past it the pipe is still read and discarded,
    /// not killed: a `> cmd` has no timeout and must finish its side effects, and a child
    /// writing into a full pipe would block forever. `> cmd` is read by a human: 1 MiB
    /// plus the marker. host.shell.run output is parsed (bookmarks JSON), so its cap is a
    /// memory guard only and truncation is reported as a flag, never in the text.
    static let outputCap = 1 << 20
    static let hostOutputCap = 64 << 20
    static let truncationMarker = "[output truncated at 1 MiB]"
    /// Tests never run a real login shell (it sources the operator's zprofile).
    static let shellFlag = NSClassFromString("XCTestCase") == nil ? "-lc" : "-c"

    /// `> cmd`: 1 MiB, marker appended on truncation.
    static func run(_ command: String) async -> String {
        let r = await run(command, cap: outputCap)
        return r.truncated ? r.text + "\n" + truncationMarker : r.text
    }

    static func run(_ command: String, cap: Int) async -> (text: String, truncated: Bool) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return ("", false) }
        let job = Job()
        // The kill makes the read below hit EOF, so the single resume still runs: a cancel
        // racing a normal exit can neither double-resume nor leak the continuation.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: job.execute(cmd, cap: cap))
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            let pid = self.pid
            lock.unlock()
            // Foundation spawns the child as its own group leader (ProcessGroupKillTests).
            if pid > 0 { CodexHarness.killGroup(pid, grace: 1) }
        }

        func execute(_ cmd: String, cap: Int) -> (text: String, truncated: Bool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Login shell (`-l`): sources /etc/zprofile (path_helper adds
            // /usr/local/bin) and ~/.zprofile (e.g. `brew shellenv` adds
            // /opt/homebrew/bin). A GUI app launched by LaunchServices only
            // inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin, so without this a
            // bare `code`, `cursor`, `gh`, etc. is not found.
            process.arguments = [ShellRunner.shellFlag, cmd]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Spawn under the lock so a cancel either sees the pid or stops the spawn.
            lock.lock()
            guard !cancelled else { lock.unlock(); return ("", false) }
            do {
                try process.run()
            } catch {
                lock.unlock()
                return ("error: \(error.localizedDescription)", false)
            }
            pid = process.processIdentifier
            lock.unlock()

            var data = Data()
            var truncated = false
            let reader = pipe.fileHandleForReading
            while true {
                let chunk = reader.availableData   // blocks until data or EOF
                if chunk.isEmpty { break }
                let room = cap - data.count
                if chunk.count > room { truncated = true }
                data.append(chunk.prefix(room))
            }
            process.waitUntilExit()
            lock.lock()
            pid = 0   // reaped: a late cancel must not signal a recycled pid
            lock.unlock()
            // decoding (not String(data:)): a cap cut inside a UTF-8 sequence must not blank the output.
            return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), truncated)
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
    /// Opens Prosper's own Settings window. The runner is the one surface that is
    /// always reachable (⌘Space), so it must offer a way in: the ⌥\ hotkey can be
    /// rebound or cleared, and the menu-bar icon can be switched off — or tucked
    /// into Prosper's own hidden menu-bar section — leaving no other route.
    case openSettings
    /// Opens the volume mixer popover from its menu-bar item. No-op when the
    /// mixer is off — there is then no status item to anchor the popover to.
    case openVolumeMixer
    /// Drag a screen region, then copy whatever text (or barcode payload) it holds.
    case copyScreenText
    /// Pick a pixel colour anywhere on screen and copy its sRGB hex.
    case pickColor

    static func parse(_ input: String) -> MetaCommand? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case ":q", ":quit": return .quit
        case ":c", ":clear": return .clearClipboard
        case "ql new", "ql create", "ql add": return .newQuicklink
        // Colon-prefixed so they can't shadow an app search for "settings" /
        // "preferences" (System Settings.app must still win that).
        case ":s", ":settings", ":prefs", ":preferences": return .openSettings
        case ":v", ":volume", ":mixer": return .openVolumeMixer
        case ":ocr", ":text", ":scan": return .copyScreenText
        case ":color", ":pick": return .pickColor
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .quit: return "Quit Prosper"
        case .clearClipboard: return "Clear clipboard history"
        case .newQuicklink: return "Create Quicklink"
        case .openSettings: return "Open Prosper Settings"
        case .openVolumeMixer: return "Open Volume Mixer"
        case .copyScreenText: return "Copy Text from Screen"
        case .pickColor: return "Pick Color from Screen"
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
        let mirror = Preferences.defaults.string(forKey: mirrorKey)

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
            Preferences.defaults.set(json, forKey: mirrorKey)
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
        guard let raw = Preferences.defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private static func store(_ map: [String: String], _ key: String) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        Preferences.defaults.set(json, forKey: key)
    }
}
