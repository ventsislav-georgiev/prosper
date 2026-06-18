import Foundation

/// Discovers MCP servers and plugins already configured in the user's home directory
/// by other coding tools (Claude Code, opencode, codex), so the settings UI can offer
/// 1-click import per item instead of hunting for config files. Read-only — nothing is
/// copied or written until the user picks an item.
enum ExternalConfigScanner {
    struct FoundServer: Identifiable {
        var id: String { "\(source)\u{0}\(server.id)" }
        let source: String      // human label, e.g. "Claude Code"
        let server: MCPServer
    }

    /// A discovered plugin. Two flavours: an opencode JS file (runnable via the Bun
    /// bridge) or a Claude Code plugin (a bundle whose importable artifacts are MCP
    /// servers + slash commands — we don't run its JS).
    struct FoundPlugin: Identifiable {
        var id: String { "\(source)\u{0}\(name)" }
        let source: String
        let name: String
        let detail: String           // short subtitle (filename or artifact summary)
        let opencodeFile: URL?       // non-nil → copy into the Bun plugins dir
        let commandFiles: [URL]      // CC plugin commands (.md/.toml) to import
        let claudeRoot: URL?         // CC plugin install root (for hooks.json import)
    }

    /// Config files we know how to parse, with a display label. Paths are relative to home.
    private static let configFiles: [(label: String, relPath: String)] = [
        ("Claude Code", ".claude.json"),
        ("Claude Code", ".config/claude/claude_desktop_config.json"),
        ("opencode", ".config/opencode/opencode.json"),
        ("opencode", ".config/opencode/opencode.jsonc"),
        ("codex", ".codex/config.toml"),
    ]

    /// opencode keeps plugins as `.js/.ts` files under these dirs.
    private static let pluginDirs: [(label: String, relPath: String)] = [
        ("opencode", ".config/opencode/plugin"),
    ]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// All MCP servers found across known configs + Claude Code plugins (deduped by id,
    /// first source wins).
    static func servers() -> [FoundServer] {
        var seen = Set<String>()
        var out: [FoundServer] = []
        func take(_ label: String, _ text: String) {
            for s in MCPConfigStore.importServers(from: text) where !seen.contains(s.id) {
                seen.insert(s.id)
                out.append(FoundServer(source: label, server: s))
            }
        }
        for (label, rel) in configFiles {
            let url = home.appendingPathComponent(rel)
            if let text = try? String(contentsOf: url, encoding: .utf8) { take(label, text) }
        }
        // Claude Code plugins ship their MCP servers in a bundled `.mcp.json` that uses
        // ${CLAUDE_PLUGIN_ROOT} — resolve it to the install path so the command is runnable.
        for plugin in claudePlugins() {
            let mcp = plugin.root.appendingPathComponent(".mcp.json")
            guard let text = try? String(contentsOf: mcp, encoding: .utf8) else { continue }
            let resolved = text.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: plugin.root.path)
            take("CC: \(plugin.name)", resolved)
        }
        return out
    }

    /// Plugins found on disk: opencode JS files + Claude Code plugin bundles.
    static func plugins() -> [FoundPlugin] {
        var out: [FoundPlugin] = []
        for (label, rel) in pluginDirs {
            let dir = home.appendingPathComponent(rel)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !name.hasPrefix(".")
                && name.range(of: #"\.(m?[jt]s)$"#, options: .regularExpression) != nil {
                out.append(FoundPlugin(source: label, name: name, detail: "opencode plugin",
                                       opencodeFile: dir.appendingPathComponent(name),
                                       commandFiles: [], claudeRoot: nil))
            }
        }
        // Every installed Claude Code plugin is listed (parity with CC's own manager),
        // with a summary of what it carries. "Add" imports the slash commands.
        for plugin in claudePlugins() {
            let cmds = commandFiles(in: plugin.root)
            out.append(FoundPlugin(source: "Claude Code", name: plugin.name,
                                   detail: artifactSummary(plugin.root, commands: cmds.count),
                                   opencodeFile: nil, commandFiles: cmds, claudeRoot: plugin.root))
        }
        return out
    }

    /// Human summary of a plugin's importable/notable artifacts.
    private static func artifactSummary(_ root: URL, commands: Int) -> String {
        let fm = FileManager.default
        func has(_ rel: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(rel).path) }
        var parts: [String] = []
        if commands > 0 { parts.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if has(".mcp.json") { parts.append("MCP") }
        if has("agents") { parts.append("agents") }
        if has("skills") { parts.append("skills") }
        if has("hooks") { parts.append("hooks") }
        return parts.isEmpty ? "plugin" : parts.joined(separator: " · ")
    }

    /// Extract (commandName, body) from a Claude Code command file. Supports `.md`
    /// (body = file contents) and `.toml` (body = the `prompt` value, with CC's
    /// `{{args}}` rewritten to our `$ARGUMENTS`).
    static func commandBody(_ url: URL) -> (name: String, body: String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension == "toml" {
            guard let prompt = tomlPrompt(text) else { return nil }
            return (name, prompt.replacingOccurrences(of: "{{args}}", with: "$ARGUMENTS"))
        }
        return (name, text)
    }

    /// Pull the `prompt = "…"` / `prompt = """…"""` value out of a TOML command file.
    private static func tomlPrompt(_ text: String) -> String? {
        guard let r = text.range(of: #"(?m)^\s*prompt\s*=\s*"#, options: .regularExpression) else { return nil }
        let rest = text[r.upperBound...]
        if rest.hasPrefix("\"\"\"") {
            let body = rest.dropFirst(3)
            guard let end = body.range(of: "\"\"\"") else { return nil }
            return String(body[..<end.lowerBound]).trimmingCharacters(in: .newlines)
        }
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
        return nil
    }

    // MARK: Claude Code plugins

    /// (name, installRoot) for every installed Claude Code plugin.
    static func claudePlugins() -> [(name: String, root: URL)] {
        let file = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return [] }
        var out: [(String, URL)] = []
        for (key, value) in plugins {
            // First install entry wins; key is "name@marketplace".
            guard let entries = value as? [[String: Any]],
                  let path = entries.first?["installPath"] as? String else { continue }
            let name = key.split(separator: "@").first.map(String.init) ?? key
            out.append((name, URL(fileURLWithPath: path)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Lifecycle hooks a CC plugin ships in `hooks/hooks.json` (or `hooks.json`),
    /// with `${CLAUDE_PLUGIN_ROOT}` resolved to the install path so the commands run.
    static func claudeHooks(root: URL) -> [HookRule] {
        for rel in ["hooks/hooks.json", "hooks.json"] {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let resolved = text.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: root.path)
            return HooksConfigStore.importHooks(from: resolved)
        }
        return []
    }

    private static func commandFiles(in root: URL) -> [URL] {
        let dir = root.appendingPathComponent("commands")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") || $0.hasSuffix(".toml") }.sorted()
            .map { dir.appendingPathComponent($0) }
    }
}
