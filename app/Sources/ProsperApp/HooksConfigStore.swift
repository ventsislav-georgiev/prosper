import Foundation
import os
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
    /// Settable so tests can point bootstrap at a scratch directory.
    nonisolated(unsafe) static var fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/prosper/hooks.json", isDirectory: false)

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

    /// Only write `enabled` when false, so a default file stays plain CC.
    private static func handler(for h: HookRule) -> Handler {
        Handler(type: "command", command: h.command, timeout: h.timeout, enabled: h.enabled ? nil : false)
    }

    /// The matcher as written: only for tool events, and only when set.
    private static func writtenMatcher(_ event: HookRule.Event, _ matcher: String) -> String? {
        (event.usesMatcher && !matcher.isEmpty) ? matcher : nil
    }

    // MARK: - Keys the app does not model (#1045)

    /// Every key `Handler` / `MatcherGroup` models (property names are the JSON keys).
    private static let handlerKeys = Set(Mirror(reflecting: Handler()).children.compactMap { $0.label })
    private static let groupKeys = Set(Mirror(reflecting: MatcherGroup()).children.compactMap { $0.label })

    /// A command handler read from the file, with the group it sits in.
    private struct Written {
        let rule: String      // event, matcher as written, command: what a rule is across a rewrite
        let exact: String     // plus timeout and enabled
        let group: OrderedJSON.Value
        let handler: OrderedJSON.Value
    }

    private static func ruleKey(_ event: HookRule.Event, _ matcher: String, _ command: String) -> String {
        "\(event.rawValue)\u{0}\(writtenMatcher(event, matcher) ?? "")\u{0}\(command)"
    }

    private static func elements(_ value: OrderedJSON.Value?) -> [OrderedJSON.Node] {
        if case .array(let list)? = value { return list }
        return []
    }

    /// The reader makes a rule of this handler (as `rules(from:)`: `type` command or none, and a
    /// non-empty `command`). Any other handler is not read, so a rewrite keeps it as written.
    private static func makesRule(_ value: OrderedJSON.Value) -> Bool {
        guard let m = MCPConfigStore.members(value), case .string(let command)? = m["command"],
              !command.isEmpty else { return false }
        switch m["type"] {
        case nil, .null?: return true
        case .string(let t)?: return t == "command"
        default: return false
        }
    }

    /// Pairs each rule with the handler it was written from: first one equal in every modelled
    /// field, then one with the same event, matcher and command (a toggled or re-timed rule).
    /// Each handler goes to one rule at most, so a rule's unknown keys never move to another.
    private static func match(_ hooks: [HookRule], _ written: [Written]) -> [Written?] {
        var free: [Written?] = written
        var out = [Written?](repeating: nil, count: hooks.count)
        for exact in [true, false] {
            for (i, h) in hooks.enumerated() where out[i] == nil {
                let rule = ruleKey(h.event, h.matcher, h.command)
                let full = rule + "\u{0}\(h.timeout.map { String($0) } ?? "")\u{0}\(h.enabled)"
                guard let j = free.firstIndex(where: { w in w.map { exact ? $0.exact == full : $0.rule == rule } ?? false })
                else { continue }
                out[i] = free[j]
                free[j] = nil
            }
        }
        return out
    }

    // MARK: - File read / write

    /// Decode our canonical file (or any CC-shaped `hooks` JSON). nil on malformed JSON
    /// so the caller keeps the last good config.
    static func decode(_ json: String) -> [HookRule]? {
        guard let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        return sorted(rules(from: doc.hooks))
    }

    /// The file text for `hooks`, one matcher group per rule. With `disk` (the file as it is
    /// now), what the app does not model is kept: top-level keys, unknown event names, groups
    /// and handlers of other kinds, and the unknown keys of each rule's group and handler. A rule
    /// removed in the app, or one whose event, matcher or command changed, has none (#1045).
    static func encode(_ hooks: [HookRule], over disk: OrderedJSON.Value? = nil) -> String? {
        typealias J = MCPConfigStore
        let old = J.members(J.members(disk)?["hooks"]) ?? [:]
        var out = old.filter { HookRule.Event(rawValue: $0.key) == nil }  // not the app's: kept whole
        var kept: [String: [OrderedJSON.Node]] = [:]  // groups or handlers the app does not read
        var written: [Written] = []
        for (name, value) in old {
            guard let event = HookRule.Event(rawValue: name) else { continue }
            for g in elements(value) {
                let gm = J.members(g.value) ?? [:]
                let handlers = elements(gm["hooks"])
                let commands = handlers.filter { makesRule($0.value) }
                let others = handlers.filter { !makesRule($0.value) }
                if commands.isEmpty { kept[name, default: []].append(g); continue }
                if !others.isEmpty {
                    var rest = gm
                    rest["hooks"] = .array(others)
                    kept[name, default: []].append(J.node(J.object(rest)))
                }
                var matcher = ""
                if case .string(let m)? = gm["matcher"] { matcher = m }
                for c in commands {
                    let hm = J.members(c.value) ?? [:]
                    var command = "", timeout = ""
                    if case .string(let s)? = hm["command"] { command = s }
                    if case .number(let n)? = hm["timeout"] { timeout = n }
                    var enabled = true
                    if case .bool(false)? = hm["enabled"] { enabled = false }
                    let rule = ruleKey(event, matcher, command)
                    written.append(Written(rule: rule, exact: rule + "\u{0}\(timeout)\u{0}\(enabled)",
                                           group: g.value, handler: c.value))
                }
            }
        }
        var groups: [String: [OrderedJSON.Node]] = [:]
        // A rule with an empty command is not written: the reader would not read it back, so
        // its handler would be kept as unread and the rule written again on every rewrite.
        for (h, w) in zip(hooks, match(hooks, written)) where !h.command.isEmpty {
            guard var gm = J.members(J.tree(MatcherGroup(matcher: writtenMatcher(h.event, h.matcher)))),
                  let hm = J.members(J.tree(handler(for: h))) else { return nil }
            gm["hooks"] = .array([J.node(J.object(J.keepingUnknown(w?.handler, in: hm, modelled: handlerKeys)))])
            groups[h.event.rawValue, default: []].append(J.node(J.object(J.keepingUnknown(w?.group, in: gm, modelled: groupKeys))))
        }
        for (name, list) in groups.merging(kept, uniquingKeysWith: +) { out[name] = .array(list) }
        return OrderedJSON.render(J.object(J.keepingUnknown(disk, in: ["hooks": J.object(out)], modelled: ["hooks"])))
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
        guard let url = MCPConfigStore.symlinkTarget(fileURL) else { return }
        var disk: OrderedJSON.Value?
        if MCPConfigStore.entryExists(url) {
            // A file the app cannot read is the user's, as in bootstrap: never replaced (#1045).
            guard let tree = MCPConfigStore.readableTree(url, key: "hooks", decodes: { decode($0) != nil }) else {
                Logger(subsystem: "eu.illegible.prosper", category: "hooks")
                    .error("\(url.path, privacy: .public) cannot be read as a hooks config; write skipped, file left untouched")
                return
            }
            disk = tree
        }
        guard let json = encode(hooks, over: disk) else { return }
        if json == Preferences.defaults.string(forKey: mirrorKey) { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            Preferences.defaults.set(json, forKey: mirrorKey)
        } catch { NSLog("prosper: failed to write hooks.json: \(error)") }
    }

    private static func readFileRaw() -> String? { try? String(contentsOf: fileURL, encoding: .utf8) }

    /// Launch reconcile: an external file edit wins; otherwise (re)write the file from
    /// the loaded prefs so in-app changes since the last launch land on disk.
    static func bootstrap() {
        let onDisk = readFileRaw()
        let mirror = Preferences.defaults.string(forKey: mirrorKey)
        if let onDisk, onDisk != mirror {
            // A hand edit that does not parse is the user's work in progress: never
            // overwrite it. Keep the last good config live (as the watcher does).
            guard let hooks = decode(onDisk) else {
                Logger(subsystem: "eu.illegible.prosper", category: "hooks")
                    .error("\(fileURL.path, privacy: .public) failed to parse at launch; left untouched, using last good config")
                return
            }
            Preferences.hooks = hooks
            Preferences.defaults.set(onDisk, forKey: mirrorKey)
        } else {
            // Absent file: forget the mirror so writeFile's no-change skip can't leave it missing.
            guard MCPConfigStore.entryExists(fileURL) else {
                Preferences.defaults.removeObject(forKey: mirrorKey)
                writeFile(Preferences.hooks)
                return
            }
            // Present but unreadable (non-UTF-8, no permission, a directory, a dangling
            // symlink): the user's file, not ours to replace. Same as a malformed hand edit.
            if onDisk == nil {
                Logger(subsystem: "eu.illegible.prosper", category: "hooks")
                    .error("\(fileURL.path, privacy: .public) is not readable as UTF-8 text at launch; left untouched, using last good config")
                return
            }
            writeFile(Preferences.hooks)
        }
    }

    /// Watcher entry point. If the file changed since our last write AND parses cleanly,
    /// commit it to prefs and return the new list. nil = no change, or broken (last good
    /// config stays live).
    @discardableResult
    static func reloadIfChanged() -> [HookRule]? {
        guard let onDisk = readFileRaw() else { return nil }
        if onDisk == Preferences.defaults.string(forKey: mirrorKey) { return nil }
        guard let hooks = decode(onDisk) else {
            NSLog("prosper: hooks.json changed but failed to parse — keeping last good config")
            return nil
        }
        Preferences.hooks = hooks
        Preferences.defaults.set(onDisk, forKey: mirrorKey)
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
        if let doc = try? TOMLDecoder().decodeGuarded(TomlDoc.self, from: text),
           let hooks = doc.hooks, !hooks.isEmpty {
            return sorted(rules(from: hooks))
        }
        return []
    }
}
