import Foundation
import os
import TOMLDecoder

extension Notification.Name {
    /// Posted (object = `[MCPServer]`) when an external edit to `mcp.json` parsed
    /// cleanly and replaced the loaded servers, so a live Settings window can refresh.
    static let mcpServersReloadedExternally = Notification.Name("mcpServersReloadedExternally")
}

/// Plain-text mirror of the coding agent's MCP servers at
/// `~/.config/prosper/mcp.json`, in Claude Code's `mcpServers` schema (the de-facto
/// standard — so importing a Claude Code `.mcp.json` is just dropping it here, and our
/// own writes stay CC-compatible).
///
/// Reconciled with `Preferences.mcpServers` at launch (`bootstrap`) and watched at
/// runtime (`FileWatcher`, wired in `AppDelegate`): an external edit that parses
/// cleanly overrides the loaded settings; a broken file is ignored so the last good
/// config stays live. In-app edits mirror back out via `writeFile`.
///
/// `importServers(from:)` additionally parses *foreign* coding-tool configs (codex
/// `config.toml`, opencode `opencode.json`, Claude Code `.mcp.json`) for the Settings
/// importer.
///
/// ponytail: arbitrary HTTP `headers` are intentionally NOT modeled — `MCPServer`
/// supports a bearer-token env var (codex `bearer_token_env_var`), which covers the
/// common auth case. Imported entries with custom headers keep their URL; the header
/// must be re-added as a bearer-token env var by hand. Add a `headers` map (+ a
/// backward-compatible `MCPServer` Codable migration) if real configs need it.
enum MCPConfigStore {
    /// Settable so tests can point bootstrap at a scratch directory.
    nonisolated(unsafe) static var fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/prosper/mcp.json", isDirectory: false)

    /// The last JSON we wrote, so the watcher can tell our own writes from an external
    /// edit and skip the reload our write would otherwise trigger.
    private static let mirrorKey = "agentMCPDiskMirror"

    // MARK: - Canonical on-disk schema (Claude Code `mcpServers`)

    struct Document: Codable { var mcpServers: [String: Entry] }

    /// Optional throughout so a partially hand-edited file still decodes. Field names
    /// match Claude Code; `bearerTokenEnvVar`/`approvalMode` are our additions.
    struct Entry: Codable {
        var type: String?                 // "stdio" | "http" | "sse"
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var url: String?
        var bearerTokenEnvVar: String?
        var approvalMode: String?
        var enabled: Bool?

        init(type: String? = nil, command: String? = nil, args: [String]? = nil,
             env: [String: String]? = nil, url: String? = nil,
             bearerTokenEnvVar: String? = nil, approvalMode: String? = nil,
             enabled: Bool? = nil) {
            self.type = type; self.command = command; self.args = args; self.env = env
            self.url = url; self.bearerTokenEnvVar = bearerTokenEnvVar
            self.approvalMode = approvalMode; self.enabled = enabled
        }
    }

    // MARK: - Model <-> Entry

    static func entry(from s: MCPServer) -> Entry {
        switch s.transport {
        case .stdio:
            return Entry(type: "stdio", command: s.command,
                         args: s.args.isEmpty ? nil : s.args,
                         env: s.env.isEmpty ? nil : s.env,
                         approvalMode: s.approvalMode.rawValue, enabled: s.enabled)
        case .http:
            return Entry(type: "http", url: s.url,
                         bearerTokenEnvVar: s.bearerTokenEnvVar.isEmpty ? nil : s.bearerTokenEnvVar,
                         approvalMode: s.approvalMode.rawValue, enabled: s.enabled)
        }
    }

    static func server(id: String, from e: Entry) -> MCPServer {
        // http when the type says so, or (typeless) when there's a url but no command.
        let isHTTP = e.type.map(isHTTPType) ?? (e.command == nil && e.url != nil)
        var s = MCPServer(id: id, transport: isHTTP ? .http : .stdio, enabled: e.enabled ?? true)
        s.command = e.command ?? ""
        s.args = e.args ?? []
        s.env = e.env ?? [:]
        s.url = e.url ?? ""
        s.bearerTokenEnvVar = e.bearerTokenEnvVar ?? ""
        if let m = e.approvalMode.flatMap(MCPServer.ApprovalMode.init) { s.approvalMode = m }
        return s
    }

    private static func isHTTPType(_ t: String) -> Bool {
        ["http", "sse", "streamable-http", "streamablehttp", "remote"].contains(t.lowercased())
    }

    // MARK: - File read / write

    /// Decode our canonical file (or any CC-shaped `mcpServers` JSON). nil on malformed
    /// JSON so the caller keeps the last good config.
    static func decode(_ json: String) -> [MCPServer]? {
        guard let data = json.data(using: .utf8),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        return doc.mcpServers
            .map { server(id: $0.key, from: $0.value) }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    /// The file text for `servers`. With `disk` (the file as it is now), every key the model
    /// does not know is kept, at the top level and in each server that still exists; a server
    /// is its id, so one removed or renamed in the app goes with its unknown keys (#1045).
    static func encode(_ servers: [MCPServer], over disk: OrderedJSON.Value? = nil) -> String? {
        let map = Dictionary(servers.map { ($0.id, entry(from: $0)) }, uniquingKeysWith: { a, _ in a })
        let old = members(members(disk)?["mcpServers"]) ?? [:]
        var out: [String: OrderedJSON.Value] = [:]
        for (id, e) in map {
            guard var ours = members(tree(e)) else { return nil }
            // The file's own `type` ("sse", "SSE") stays while it reads back as the transport the
            // app holds; absent, or naming the other transport, the app's value is written.
            if case .string(let t)? = members(old[id])?["type"], e.type.map(isHTTPType) == isHTTPType(t) {
                ours["type"] = .string(t)
            }
            out[id] = object(keepingUnknown(old[id], in: ours, modelled: entryKeys))
        }
        return OrderedJSON.render(object(keepingUnknown(disk, in: ["mcpServers": object(out)], modelled: ["mcpServers"])))
    }

    /// Every key `Entry` models (its property names are its JSON keys).
    private static let entryKeys = Set(Mirror(reflecting: Entry()).children.compactMap { $0.label })

    /// Mirror the loaded servers out to the file. Skips the write (and the watcher
    /// reload it would cause) when the content is unchanged.
    static func writeFile(_ servers: [MCPServer]) {
        guard let url = symlinkTarget(fileURL) else { return }
        var disk: OrderedJSON.Value?
        if entryExists(url) {
            // A file the app cannot read is the user's, as in bootstrap: never replaced (#1045).
            guard let tree = readableTree(url, key: "mcpServers", decodes: { decode($0) != nil }) else {
                Logger(subsystem: "eu.illegible.prosper", category: "mcp")
                    .error("\(url.path, privacy: .public) cannot be read as an MCP config; write skipped, file left untouched")
                return
            }
            disk = tree
        }
        guard let json = encode(servers, over: disk) else { return }
        if json == Preferences.defaults.string(forKey: mirrorKey) { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            Preferences.defaults.set(json, forKey: mirrorKey)
        } catch { NSLog("prosper: failed to write mcp.json: \(error)") }
    }

    /// Where a config write lands: a symlinked config (kept in a dotfiles repo) is
    /// followed, dangling or not, so the atomic replace hits the target and the link
    /// survives (#391). Shared with `HooksConfigStore`. nil when the chain does not
    /// resolve (a cycle, or more than 8 hops): the write is skipped rather than
    /// replacing a link in the user's dotfiles with a regular file (#399).
    static func symlinkTarget(_ url: URL) -> URL? {
        var url = url
        for _ in 0..<8 {  // bounded: a link cycle stops here instead of spinning
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return url }
            url = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return url }
        Logger(subsystem: "eu.illegible.prosper", category: "mcp")
            .error("\(url.path, privacy: .public) is still a symlink after 8 hops (cycle or long chain); config write skipped")
        return nil
    }

    /// lstat existence: a symlink, even dangling, is the user's file, not absent (#391).
    static func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func readFileRaw() -> String? { try? String(contentsOf: fileURL, encoding: .utf8) }

    // MARK: - Keys the app does not model (#1045), shared with `HooksConfigStore`

    /// The file at `url` as a JSON tree when the app can read it: UTF-8 strict JSON (OrderedJSON
    /// keeps each number as written) with an object at the top, which the store's decoder accepts
    /// or which has no `key` at all (`{}`, a settings.json with no hooks). nil otherwise.
    static func readableTree(_ url: URL, key: String, decodes: (String) -> Bool) -> OrderedJSON.Value? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let doc = try? OrderedJSON(text), let top = members(doc.root.value),
              top[key] == nil || decodes(text) else { return nil }
        return doc.root.value
    }

    /// An object's members by key; nil when `value` is not an object (OrderedJSON refuses
    /// duplicate keys, so none are merged).
    static func members(_ value: OrderedJSON.Value?) -> [String: OrderedJSON.Value]? {
        guard case .object(let list)? = value else { return nil }
        return Dictionary(list.map { ($0.key, $0.value.value) }, uniquingKeysWith: { _, last in last })
    }

    /// An object with its keys sorted, as the file has always been written. The renderer
    /// reads no ranges.
    static func object(_ members: [String: OrderedJSON.Value]) -> OrderedJSON.Value {
        .object(members.sorted { $0.key < $1.key }.map { OrderedJSON.Member(key: $0.key, start: 0, value: node($0.value)) })
    }

    static func node(_ value: OrderedJSON.Value) -> OrderedJSON.Node { .init(value: value, range: 0..<0) }

    /// `ours` plus the keys of `old` outside `modelled`. A modelled key always comes from
    /// `ours`, so a value the app cleared is not brought back from the file.
    static func keepingUnknown(_ old: OrderedJSON.Value?, in ours: [String: OrderedJSON.Value],
                               modelled: Set<String>) -> [String: OrderedJSON.Value] {
        (members(old) ?? [:]).filter { !modelled.contains($0.key) }.merging(ours) { $1 }
    }

    /// The app's own value as a JSON tree.
    static func tree<T: Encodable>(_ value: T) -> OrderedJSON.Value? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? OrderedJSON(bytes: Array(data)))?.root.value
    }

    /// Launch reconcile (mirrors `QuicklinkStore`): an external file edit wins;
    /// otherwise (re)write the file from the loaded prefs so in-app changes since the
    /// last launch land on disk.
    static func bootstrap() {
        let onDisk = readFileRaw()
        let mirror = Preferences.defaults.string(forKey: mirrorKey)
        if let onDisk, onDisk != mirror {
            // A hand edit that does not parse is the user's work in progress: never
            // overwrite it. Keep the last good config live (as the watcher does).
            guard let servers = decode(onDisk) else {
                Logger(subsystem: "eu.illegible.prosper", category: "mcp")
                    .error("\(fileURL.path, privacy: .public) failed to parse at launch; left untouched, using last good config")
                return
            }
            Preferences.mcpServers = servers
            Preferences.defaults.set(onDisk, forKey: mirrorKey)
        } else {
            // Absent file: forget the mirror so writeFile's no-change skip can't leave it missing.
            guard entryExists(fileURL) else {
                Preferences.defaults.removeObject(forKey: mirrorKey)
                writeFile(Preferences.mcpServers)
                return
            }
            // Present but unreadable (non-UTF-8, no permission, a directory, a dangling
            // symlink): the user's file, not ours to replace. Same as a malformed hand edit.
            if onDisk == nil {
                Logger(subsystem: "eu.illegible.prosper", category: "mcp")
                    .error("\(fileURL.path, privacy: .public) is not readable as UTF-8 text at launch; left untouched, using last good config")
                return
            }
            writeFile(Preferences.mcpServers)
        }
    }

    /// Watcher entry point. If the file changed since our last write AND parses
    /// cleanly, commit it to prefs and return the new list. nil = no change, or broken
    /// (last good config stays live).
    @discardableResult
    static func reloadIfChanged() -> [MCPServer]? {
        guard let onDisk = readFileRaw() else { return nil }
        if onDisk == Preferences.defaults.string(forKey: mirrorKey) { return nil }
        guard let servers = decode(onDisk) else {
            NSLog("prosper: mcp.json changed but failed to parse — keeping last good config")
            return nil
        }
        Preferences.mcpServers = servers
        Preferences.defaults.set(onDisk, forKey: mirrorKey)
        return servers
    }

    // MARK: - Foreign-config import (Settings "Import…")

    /// Parse a config blob from another coding tool into our model. Autodetects codex
    /// `config.toml` (`[mcp_servers.*]`), then JSON in either Claude Code shape
    /// (`mcpServers`) or opencode shape (`mcp`). Returns [] if nothing recognizable.
    static func importServers(from text: String) -> [MCPServer] {
        if let toml = importCodexTOML(text), !toml.isEmpty { return sortedByID(toml) }
        if let json = importJSON(text), !json.isEmpty { return sortedByID(json) }
        return []
    }

    private static func sortedByID(_ s: [MCPServer]) -> [MCPServer] {
        s.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    private static func importJSON(_ text: String) -> [MCPServer]? {
        guard let data = text.data(using: .utf8) else { return nil }
        // Claude Code / our own canonical file.
        if let doc = try? JSONDecoder().decode(Document.self, from: data), !doc.mcpServers.isEmpty {
            return doc.mcpServers.map { server(id: $0.key, from: $0.value) }
        }
        // opencode `mcp` (command is an argv array; `environment` not `env`).
        struct OcDoc: Codable { var mcp: [String: OcEntry] }
        struct OcEntry: Codable {
            var type: String?               // "local" | "remote"
            var command: [String]?
            var environment: [String: String]?
            var url: String?
            var enabled: Bool?
        }
        if let oc = try? JSONDecoder().decode(OcDoc.self, from: data), !oc.mcp.isEmpty {
            return oc.mcp.map { id, e in
                let isRemote = (e.type?.lowercased() == "remote") || (e.command == nil && e.url != nil)
                var s = MCPServer(id: id, transport: isRemote ? .http : .stdio, enabled: e.enabled ?? true)
                if let cmd = e.command, !cmd.isEmpty {
                    s.command = cmd[0]
                    s.args = Array(cmd.dropFirst())
                }
                s.env = e.environment ?? [:]
                s.url = e.url ?? ""
                return s
            }
        }
        return nil
    }

    private static func importCodexTOML(_ text: String) -> [MCPServer]? {
        struct Doc: Codable { var mcp_servers: [String: CodexEntry]? }
        struct CodexEntry: Codable {
            var command: String?
            var args: [String]?
            var env: [String: String]?
            var url: String?
            var bearer_token_env_var: String?
            var enabled: Bool?
            var default_tools_approval_mode: String?
        }
        guard let doc = try? TOMLDecoder().decodeGuarded(Doc.self, from: text),
              let servers = doc.mcp_servers, !servers.isEmpty else { return nil }
        return servers.map { id, e in
            let isHTTP = e.command == nil && e.url != nil
            var s = MCPServer(id: id, transport: isHTTP ? .http : .stdio, enabled: e.enabled ?? true)
            s.command = e.command ?? ""
            s.args = e.args ?? []
            s.env = e.env ?? [:]
            s.url = e.url ?? ""
            s.bearerTokenEnvVar = e.bearer_token_env_var ?? ""
            if let m = e.default_tools_approval_mode.flatMap(MCPServer.ApprovalMode.init) {
                s.approvalMode = m
            }
            return s
        }
    }
}
