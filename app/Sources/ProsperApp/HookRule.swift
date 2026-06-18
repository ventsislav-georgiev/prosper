import Foundation

/// One lifecycle hook for the coding agent, rendered into the codex
/// `CODEX_HOME/config.toml` as a `[[hooks.<Event>]]` matcher group with a single
/// `type = "command"` handler. codex runs the command through `$SHELL -lc`, feeds the
/// event JSON on stdin, and parses a decision from stdout — a Claude-Code-compatible
/// contract, so a Claude Code hook command works here verbatim.
///
/// **Startup-only:** like `MCPServer`, codex reads hooks when `app-server` launches,
/// so a change applies to the NEXT agent run (the harness respawns to pick it up).
///
/// ponytail: only the `type = "command"` handler is modeled — codex also has `prompt`
/// and `agent` handler kinds, but a shell command (which can itself invoke a model or
/// the plugin bridge) covers both the Claude Code ecosystem and our Bun-plugin bridge.
struct HookRule: Codable, Identifiable, Sendable, Equatable {
    /// codex's hook events (`HOOK_EVENT_NAMES`). `matcher` only applies to the tool
    /// events (`PreToolUse`/`PostToolUse`/`PermissionRequest`); it is ignored elsewhere.
    enum Event: String, Codable, Sendable, CaseIterable {
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case userPromptSubmit = "UserPromptSubmit"
        case sessionStart = "SessionStart"
        case stop = "Stop"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case preCompact = "PreCompact"
        case postCompact = "PostCompact"

        /// Tool-targeting events where a `matcher` regex is meaningful.
        var usesMatcher: Bool {
            switch self {
            case .preToolUse, .postToolUse, .permissionRequest: return true
            default: return false
            }
        }
    }

    /// SwiftUI list identity only — never written to config. (Hook order/identity in
    /// codex is positional, not keyed, so we don't need a stable on-disk id.)
    var id: String
    var event: Event
    var matcher: String      // regex on tool name; "" = match all (omitted from TOML)
    var command: String      // shell command codex runs via `$SHELL -lc`
    var timeout: Int?        // seconds; nil = codex default
    var enabled: Bool

    init(id: String = UUID().uuidString, event: Event = .preToolUse, matcher: String = "",
         command: String = "", timeout: Int? = nil, enabled: Bool = true) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.command = command
        self.timeout = timeout
        self.enabled = enabled
    }

    /// A hook is renderable only with a non-empty command (a blank row can't run).
    var isValid: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - TOML rendering

    /// Render the `[[hooks.*]]` blocks for a hook list. Only enabled, valid hooks are
    /// emitted (a disabled hook is simply absent → codex does not run it). One matcher
    /// group per hook (codex accepts many groups per event). Returns "" when nothing is
    /// renderable so the caller can append unconditionally.
    static func tomlBlocks(for hooks: [HookRule]) -> String {
        let renderable = hooks.filter { $0.enabled && $0.isValid }
        guard !renderable.isEmpty else { return "" }
        var out = "\n"
        for h in renderable {
            let ev = h.event.rawValue
            out += "\n[[hooks.\(ev)]]\n"
            let m = h.matcher.trimmingCharacters(in: .whitespaces)
            if h.event.usesMatcher && !m.isEmpty { out += "matcher = \(MCPServer.q(m))\n" }
            out += "\n[[hooks.\(ev).hooks]]\n"
            out += "type = \"command\"\n"
            out += "command = \(MCPServer.q(h.command))\n"
            if let t = h.timeout { out += "timeout = \(t)\n" }
        }
        return out
    }
}
