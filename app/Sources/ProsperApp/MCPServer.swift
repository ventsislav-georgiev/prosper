import Foundation

/// One MCP (Model Context Protocol) server configured for the coding agent. Rendered
/// into the codex `CODEX_HOME/config.toml` as a `[mcp_servers.<id>]` block when the
/// harness spawns.
///
/// **Startup-only:** codex reads MCP config when `app-server` launches, not per turn —
/// so adding/removing a server takes effect on the NEXT agent run (an active session
/// must restart to pick it up). The Settings UI surfaces that caveat.
///
/// Two transports mirror codex rust's schema:
///   • `.stdio` — codex launches a local process (`command` + `args`, optional `env`).
///   • `.http`  — codex connects to a remote / streamable-HTTP MCP server (`url`,
///                optional bearer token sourced from a named env var).
struct MCPServer: Codable, Identifiable, Sendable, Equatable {
    enum Transport: String, Codable, Sendable, CaseIterable { case stdio, http }

    /// Per-server default tool-approval policy → codex `default_tools_approval_mode`.
    enum ApprovalMode: String, Codable, Sendable, CaseIterable {
        case auto, prompt, approve
    }

    /// TOML table key (`[mcp_servers.<id>]`) and the SwiftUI list id. Sanitized to
    /// `[A-Za-z0-9_-]` before it reaches the config file.
    var id: String
    var transport: Transport
    var enabled: Bool

    // stdio transport
    var command: String          // e.g. "npx"
    var args: [String]           // e.g. ["-y", "@upstash/context7-mcp"]
    var env: [String: String]

    // http transport
    var url: String
    var bearerTokenEnvVar: String

    var approvalMode: ApprovalMode

    init(id: String = "", transport: Transport = .stdio, enabled: Bool = true,
         command: String = "", args: [String] = [], env: [String: String] = [:],
         url: String = "", bearerTokenEnvVar: String = "",
         approvalMode: ApprovalMode = .prompt) {
        self.id = id
        self.transport = transport
        self.enabled = enabled
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.approvalMode = approvalMode
    }

    /// A server is renderable only if it has an id and the fields its transport needs.
    /// Invalid servers are silently skipped (never written) so a half-filled row can't
    /// crash codex startup.
    var isValid: Bool {
        guard !sanitizedID.isEmpty else { return false }
        switch transport {
        case .stdio: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http:  return !url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// `id` reduced to a valid TOML bare key (`-`, `_`, alphanumerics).
    var sanitizedID: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String(id.map { allowed.contains($0) ? $0 : "_" })
    }

    // MARK: - TOML rendering

    /// Render the `[mcp_servers.*]` blocks for a server list. Only enabled, valid
    /// servers are emitted (a disabled server is simply absent from the config →
    /// codex does not load it). Returns "" when nothing is renderable, so the caller
    /// can append unconditionally without disturbing a config that has no MCP servers.
    static func tomlBlocks(for servers: [MCPServer]) -> String {
        let renderable = servers.filter { $0.enabled && $0.isValid }
        guard !renderable.isEmpty else { return "" }
        var out = "\n"
        var seen = Set<String>()
        for s in renderable {
            let key = s.sanitizedID
            // Two servers collapsing to the same TOML key would produce a duplicate
            // `[mcp_servers.<key>]` table (invalid TOML) — keep the first, skip the rest.
            guard seen.insert(key).inserted else { continue }
            out += "\n[mcp_servers.\(key)]\n"
            out += "default_tools_approval_mode = \(q(s.approvalMode.rawValue))\n"
            switch s.transport {
            case .stdio:
                out += "command = \(q(s.command))\n"
                if !s.args.isEmpty {
                    out += "args = [\(s.args.map(q).joined(separator: ", "))]\n"
                }
                if !s.env.isEmpty {
                    out += "\n[mcp_servers.\(key).env]\n"
                    for k in s.env.keys.sorted() {
                        out += "\(q(k)) = \(q(s.env[k] ?? ""))\n"
                    }
                }
            case .http:
                out += "url = \(q(s.url))\n"
                if !s.bearerTokenEnvVar.trimmingCharacters(in: .whitespaces).isEmpty {
                    out += "bearer_token_env_var = \(q(s.bearerTokenEnvVar))\n"
                }
            }
        }
        return out
    }

    /// TOML basic-string quote with the escapes the spec requires. Also used by
    /// `CodexHarness.writeConfig` for its interpolated values.
    static func q(_ s: String) -> String {
        var e = ""
        for c in s {
            switch c {
            case "\\": e += "\\\\"
            case "\"": e += "\\\""
            case "\n": e += "\\n"
            case "\t": e += "\\t"
            case "\r": e += "\\r"
            default:
                // Other control chars (U+0000–U+001F, U+007F) are illegal raw in a TOML
                // basic string — emit the `\uXXXX` escape or codex fails to parse
                // config.toml at launch and the agent silently won't spawn.
                if let u = c.unicodeScalars.first, c.unicodeScalars.count == 1,
                   u.value < 0x20 || u.value == 0x7F {
                    e += String(format: "\\u%04X", u.value)
                } else {
                    e.append(c)
                }
            }
        }
        return "\"\(e)\""
    }
}
