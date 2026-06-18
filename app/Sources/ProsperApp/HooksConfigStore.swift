import Foundation
import TOMLDecoder

extension Notification.Name {
    /// Posted (object = `[HookRule]`) when an external edit to `hooks.json` parsed
    /// cleanly and replaced the loaded hooks, so a live Settings window can refresh.
    static let hooksReloadedExternally = Notification.Name("hooksReloadedExternally")
}

/// Plain-text mirror of the coding agent's lifecycle hooks at
/// `~/.config/prosper/hooks.json`, in Claude Code's `settings.json` `hooks` schema (so
/// a Claude Code hooks block imports by being dropped here, and our own writes stay
/// CC-compatible).
///
/// Reconciled with `Preferences.hooks` at launch (`bootstrap`) and watched at runtime
/// (`FileWatcher`, wired in `AppDelegate`): an external edit that parses cleanly
/// overrides the loaded hooks; a broken file is ignored so the last good config stays
/// live. In-app edits mirror back out via `writeFile`. Mirrors `MCPConfigStore`.
///
/// `importHooks(from:)` also parses a full Claude Code `settings.json` (top-level
/// `hooks`) or a codex `config.toml` `[hooks]` block for the Settings importer.
enum HooksConfigStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/hooks.json", isDirectory: false)
    }

    private static let mirrorKey = "agentHooksDiskMirror"

    // MARK: - Canonical on-disk schema (Claude Code `hooks`)

    /// A `settings.json`-shaped document. We read the `hooks` map whether the file is a
    /// full settings.json or a bare `{ "hooks": {...} }`.
    struct Document: Codable { var hooks: [String: [MatcherGroup]] }

    struct MatcherGroup: Codable {
        var matcher: String?
        var hooks: [Handler]?
    }

    /// Optional throughout so a partially hand-edited file still decodes. Field names
    /// match Claude Code; `enabled` is our addition (absent = enabled).
    struct Handler: Codable {
        var type: String?        // "command" (others ignored — see HookRule note)
        var command: String?
        var timeout: Int?
        var enabled: Bool?

        init(type: String? = nil, command: String? = nil, timeout: Int? = nil, enabled: Bool? = nil) {
            self.type = type; self.command = command; self.timeout = timeout; self.enabled = enabled
        }
    }

    // MARK: - Document <-> model

    /// Flatten a `hooks` map into our rule list. Unknown event names and non-`command`
    /// handlers are skipped (codex `prompt`/`agent` kinds aren't modeled).
    private static func rules(from hooks: [String: [MatcherGroup]]) -> [HookRule] {
        var out: [HookRule] = []
        for (eventKey, groups) in hooks {
            guard let event = HookRule.Event(rawValue: eventKey) else { continue }
            for group in groups {
                for handler in group.hooks ?? [] {
                    let kind = handler.type ?? "command"
                    guard kind == "command",
                          let command = handler.command, !command.isEmpty else { continue }
                    out.append(HookRule(event: event, matcher: group.matcher ?? "",
                                        command: command, timeout: handler.timeout,
                                        enabled: handler.enabled ?? true))
                }
            }
        }
        return out
    }

    private static func document(from hooks: [HookRule]) -> Document {
        var map: [String: [MatcherGroup]] = [:]
        for h in hooks {
            // Only write `enabled` when false, so a default file stays plain CC.
            let handler = Handler(type: "command", command: h.command, timeout: h.timeout,
                                  enabled: h.enabled ? nil : false)
            let matcher = (h.event.usesMatcher && !h.matcher.isEmpty) ? h.matcher : nil
            map[h.event.rawValue, default: []].append(MatcherGroup(matcher: matcher, hooks: [handler]))
        }
        return Document(hooks: map)
    }

    // MARK: - File read / write

    /// Decode our canonical file (or any CC-shaped `hooks` JSON). nil on malformed JSON
    /// so the caller keeps the last good config.
    static func decode(_ json: String) -> [HookRule]? {
        guard let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        return sorted(rules(from: doc.hooks))
    }

    static func encode(_ hooks: [HookRule]) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(document(from: hooks)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stable display/dedup order: by event, then matcher, then command.
    private static func sorted(_ hooks: [HookRule]) -> [HookRule] {
        hooks.sorted {
            ($0.event.rawValue, $0.matcher, $0.command) < ($1.event.rawValue, $1.matcher, $1.command)
        }
    }

    /// Mirror the loaded hooks out to the file. Skips the write (and the watcher reload
    /// it would cause) when the content is unchanged.
    static func writeFile(_ hooks: [HookRule]) {
        guard let json = encode(hooks) else { return }
        if json == UserDefaults.standard.string(forKey: mirrorKey) { return }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(json, forKey: mirrorKey)
        } catch { NSLog("prosper: failed to write hooks.json: \(error)") }
    }

    private static func readFileRaw() -> String? { try? String(contentsOf: fileURL, encoding: .utf8) }

    /// Launch reconcile: an external file edit wins; otherwise (re)write the file from
    /// the loaded prefs so in-app changes since the last launch land on disk.
    static func bootstrap() {
        let onDisk = readFileRaw()
        let mirror = UserDefaults.standard.string(forKey: mirrorKey)
        if let onDisk, onDisk != mirror, let hooks = decode(onDisk) {
            Preferences.hooks = hooks
            UserDefaults.standard.set(onDisk, forKey: mirrorKey)
        } else {
            writeFile(Preferences.hooks)
        }
    }

    /// Watcher entry point. If the file changed since our last write AND parses cleanly,
    /// commit it to prefs and return the new list. nil = no change, or broken (last good
    /// config stays live).
    @discardableResult
    static func reloadIfChanged() -> [HookRule]? {
        guard let onDisk = readFileRaw() else { return nil }
        if onDisk == UserDefaults.standard.string(forKey: mirrorKey) { return nil }
        guard let hooks = decode(onDisk) else {
            NSLog("prosper: hooks.json changed but failed to parse — keeping last good config")
            return nil
        }
        Preferences.hooks = hooks
        UserDefaults.standard.set(onDisk, forKey: mirrorKey)
        return hooks
    }

    // MARK: - Foreign-config import (Settings "Import…")

    /// Parse a hooks blob from another coding tool into our model. Accepts a Claude Code
    /// `settings.json` (or bare `{ "hooks": {...} }`), then a codex `config.toml`
    /// `[hooks]` block. Returns [] if nothing recognizable.
    static func importHooks(from text: String) -> [HookRule] {
        if let data = text.data(using: .utf8),
           let doc = try? JSONDecoder().decode(Document.self, from: data), !doc.hooks.isEmpty {
            return sorted(rules(from: doc.hooks))
        }
        // codex config.toml: `[hooks]` with `[[hooks.PreToolUse]]` matcher groups.
        struct TomlDoc: Codable { var hooks: [String: [MatcherGroup]]? }
        if let doc = try? TOMLDecoder().decode(TomlDoc.self, from: text),
           let hooks = doc.hooks, !hooks.isEmpty {
            return sorted(rules(from: hooks))
        }
        return []
    }
}
