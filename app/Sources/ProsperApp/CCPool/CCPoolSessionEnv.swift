import Foundation

/// #871 spec 3.6 + errata C8: which env a new Agent Session gets when "Start new Claude sessions
/// through the pool" is on. Pure; the spawn path applies the delta (P2b).
enum CCPool {
    /// What to change in a spawned session's environment. Empty: leave it as it is.
    struct EnvDelta: Equatable, Sendable {
        var set: [String: String] = [:]
        var remove: [String] = []
        var isEmpty: Bool { self.set.isEmpty && remove.isEmpty }

        func applied(to env: [String: String]) -> [String: String] {
            var out = env
            for k in remove { out.removeValue(forKey: k) }
            out.merge(self.set) { _, new in new }
            return out
        }
    }

    /// Credentials that would bypass the pool on a direct call; dropped whenever a session routes
    /// (the proxy supplies the account's token). QA #739 INFO-4 adds Claude Code's own OAuth token.
    static let strippedCredentials = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]

    static func baseURL(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// The program name of a command word the way dch reads it: the text after the last "/", or
    /// the whole word. Not NSString.lastPathComponent, which drops a trailing "/" (QA #726 F1):
    /// "claude/" names no program here.
    static func programName(_ word: String) -> String {
        word.lastIndex(of: "/").map { String(word[word.index(after: $0)...]) } ?? word
    }

    /// `command` is the user's command value (argv) BEFORE any login-shell wrap: the wrapped argv
    /// starts with the shell and would never route (errata C8). Off, the proxy not healthy, or a
    /// pool with no account (QA #739 F1; `CCPoolStore.hasAccounts`): no change at all. `claude` gets ANTHROPIC_BASE_URL; `headroom` gets ANTHROPIC_TARGET_API_URL
    /// and keeps ANTHROPIC_BASE_URL for itself, so ccpool stays the last hop. Anything else (a
    /// shell, `direnv exec . claude`, a custom wrapper): no change.
    static func sessionEnv(command: [String], base: String, on: Bool, healthy: Bool, hasAccounts: Bool) -> EnvDelta {
        guard on, healthy, hasAccounts, let first = command.first else { return EnvDelta() }
        switch programName(first) {
        case "claude": return EnvDelta(set: ["ANTHROPIC_BASE_URL": base], remove: strippedCredentials)
        case "headroom": return EnvDelta(set: ["ANTHROPIC_TARGET_API_URL": base], remove: strippedCredentials)
        default: return EnvDelta()
        }
    }
}
