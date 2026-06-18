import Foundation
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
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/mcp.json", isDirectory: false)
    }

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

    static func encode(_ servers: [MCPServer]) -> String? {
        let map = Dictionary(servers.map { ($0.id, entry(from: $0)) }, uniquingKeysWith: { a, _ in a })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(Document(mcpServers: map)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Mirror the loaded servers out to the file. Skips the write (and the watcher
    /// reload it would cause) when the content is unchanged.
    static func writeFile(_ servers: [MCPServer]) {
        guard let json = encode(servers) else { return }
        if json == UserDefaults.standard.string(forKey: mirrorKey) { return }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(json, forKey: mirrorKey)
        } catch { NSLog("prosper: failed to write mcp.json: \(error)") }
    }

    private static func readFileRaw() -> String? { try? String(contentsOf: fileURL, encoding: .utf8) }

    /// Launch reconcile (mirrors `QuicklinkStore`): an external file edit wins;
    /// otherwise (re)write the file from the loaded prefs so in-app changes since the
    /// last launch land on disk.
    static func bootstrap() {
        let onDisk = readFileRaw()
        let mirror = UserDefaults.standard.string(forKey: mirrorKey)
        if let onDisk, onDisk != mirror, let servers = decode(onDisk) {
            Preferences.mcpServers = servers
            UserDefaults.standard.set(onDisk, forKey: mirrorKey)
        } else {
            writeFile(Preferences.mcpServers)
        }
    }

    /// Watcher entry point. If the file changed since our last write AND parses
    /// cleanly, commit it to prefs and return the new list. nil = no change, or broken
    /// (last good config stays live).
    @discardableResult
    static func reloadIfChanged() -> [MCPServer]? {
        guard let onDisk = readFileRaw() else { return nil }
        if onDisk == UserDefaults.standard.string(forKey: mirrorKey) { return nil }
        guard let servers = decode(onDisk) else {
            NSLog("prosper: mcp.json changed but failed to parse — keeping last good config")
            return nil
        }
        Preferences.mcpServers = servers
        UserDefaults.standard.set(onDisk, forKey: mirrorKey)
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
        guard let doc = try? TOMLDecoder().decode(Doc.self, from: text),
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
