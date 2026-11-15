import Foundation
import os
import TOMLDecoder

extension Notification.Name {
    /// Posted (object = `[MCPServer]`) when an external edit to `mcp.json` parsed
    /// cleanly and replaced the loaded servers, so a live Settings window can refresh.
    static let mcpServersReloadedExternally = Notification.Name("mcpServersReloadedExternally")
    /// Posted when `MCPConfigStore.fileProblem` or `HooksConfigStore.fileProblem` changes (#1052).
    static let agentConfigFileProblemChanged = Notification.Name("agentConfigFileProblemChanged")
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

    /// Why in-app edits are not saved to the file: the reason the file as it stands cannot be read; nil
    /// while it reads or is absent (#1052). Set on every write and every look at the file (the Settings
    /// pane opening, the watcher), so it clears as soon as the file reads again.
    nonisolated(unsafe) static var fileProblem: String? {
        didSet { if fileProblem != oldValue { NotificationCenter.default.post(name: .agentConfigFileProblemChanged, object: nil) } }
    }

    /// The file a write lands on and its tree (nil: absent), or nil when it cannot be read; records `fileProblem`.
    private static func current() -> (url: URL, tree: OrderedJSON.Value?)? {
        do throws(Unreadable) {
            let read = try readCurrent(fileURL, key: "mcpServers") { _ = try JSONDecoder().decode(Document.self, from: Data($0.utf8)) }
            fileProblem = nil
            return read
        } catch {
            fileProblem = error.reason
            return nil
        }
    }

    /// Looks at the file as it stands (the Settings pane on open) and returns `fileProblem`.
    @discardableResult
    static func checkFile() -> String? {
        _ = current()
        return fileProblem
    }

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
        // A file the app cannot read is the user's, as in bootstrap: never replaced (#1045); the pane says so (#1052).
        guard let read = current() else {
            Logger(subsystem: "eu.illegible.prosper", category: "mcp")
                .error("\(fileURL.path, privacy: .public) cannot be read as an MCP config; write skipped, file left untouched")
            return
        }
        let (url, disk) = read
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

    /// Why a config file cannot be read, in words for the Settings pane (#1052).
    struct Unreadable: Error { let reason: String }

    /// Where a write of `file` lands (symlinks followed) and the tree there, nil when nothing is there.
    static func readCurrent(_ file: URL, key: String, check: (String) throws -> Void) throws(Unreadable) -> (url: URL, tree: OrderedJSON.Value?) {
        guard let url = symlinkTarget(file) else { throw Unreadable(reason: "the symlink chain is a cycle or longer than 8 links") }
        return try (url, entryExists(url) ? readableTree(url, key: key, check: check) : nil)
    }

    /// The file at `url` as a JSON tree when the app can read it: UTF-8 strict JSON (OrderedJSON
    /// keeps each number as written) with an object at the top, which the store's decoder accepts
    /// (`check` does not throw) or which has no `key` at all (`{}`, a settings.json with no hooks).
    /// Otherwise throws the reason OrderedJSON or the decoder gave (#1052).
    /// #1231: read as bytes, so a leading UTF-8 mark is skipped by OrderedJSON on every system (whether
    /// String(contentsOf:) drops it is Foundation's call); `check` gets the text after the mark, as
    /// String(contentsOf:) gives it on macOS 27. OrderedJSON(bytes:) has already refused non-UTF-8.
    static func readableTree(_ url: URL, key: String, check: (String) throws -> Void) throws(Unreadable) -> OrderedJSON.Value {
        guard let data = try? Data(contentsOf: url) else { throw Unreadable(reason: "the file cannot be opened") }
        let doc: OrderedJSON
        do { doc = try OrderedJSON(bytes: Array(data)) } catch { throw Unreadable(reason: "\(error)") }
        guard let top = members(doc.root.value) else { throw Unreadable(reason: "the top level is not a JSON object") }
        if top[key] != nil {
            do { try check(String(decoding: doc.bytes.dropFirst(OrderedJSON.markLength(doc.bytes)), as: UTF8.self)) }
            catch { throw Unreadable(reason: decodingReason(error)) }
        }
        return doc.root.value
    }

    /// The decoder's complaint as a path and the type it wanted, e.g. "mcpServers.api.enabled has the wrong type (expected Bool)".
    static func decodingReason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch(let type, let c)?, .valueNotFound(let type, let c)?:
            return "\(c.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type (expected \(type))"
        default:
            return "the file does not have the expected shape"
        }
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
        checkFile()
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
    /// A server whose id is in `existing` keeps its enabled state, approval mode and bearer token
    /// variable unless the text states them (#1052); the rest is the import's.
    static func importServers(from text: String, over existing: [MCPServer] = []) -> [MCPServer] {
        let old = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let toml = importCodexTOML(text, over: old), !toml.isEmpty { return sortedByID(toml) }
        if let json = importJSON(text, over: old), !json.isEmpty { return sortedByID(json) }
        return []
    }

    /// `s` as parsed, with the fields the text did not state (nil here) taken from `old`.
    private static func carry(_ s: MCPServer, enabled: Bool?, approval: String?, token: String?,
                              from old: MCPServer?) -> MCPServer {
        guard let old else { return s }
        var s = s
        if enabled == nil { s.enabled = old.enabled }
        if approval.flatMap(MCPServer.ApprovalMode.init) == nil { s.approvalMode = old.approvalMode }
        if token == nil { s.bearerTokenEnvVar = old.bearerTokenEnvVar }
        return s
    }

    private static func sortedByID(_ s: [MCPServer]) -> [MCPServer] {
        s.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    private static func importJSON(_ text: String, over old: [String: MCPServer]) -> [MCPServer]? {
        guard let data = text.data(using: .utf8) else { return nil }
        // Claude Code / our own canonical file.
        if let doc = try? JSONDecoder().decode(Document.self, from: data), !doc.mcpServers.isEmpty {
            return doc.mcpServers.map { id, e in
                carry(server(id: id, from: e), enabled: e.enabled, approval: e.approvalMode, token: e.bearerTokenEnvVar, from: old[id])
            }
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
                return carry(s, enabled: e.enabled, approval: nil, token: nil, from: old[id])
            }
        }
        return nil
    }

    private static func importCodexTOML(_ text: String, over old: [String: MCPServer]) -> [MCPServer]? {
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
            return carry(s, enabled: e.enabled, approval: e.default_tools_approval_mode,
                         token: e.bearer_token_env_var, from: old[id])
        }
    }
}
