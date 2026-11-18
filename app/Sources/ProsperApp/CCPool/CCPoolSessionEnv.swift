import Foundation

/// #871 spec 3.6 + errata C8: which env a new Agent Session gets when "Start new Claude sessions
/// through the pool" is on. Pure; the spawn path applies the delta (P2b).
enum CCPool {
    /// #871 P2b-2: the --spawn path applies `Routing` (AgentIslandController.sessionEnvContributors), so
    /// the pane shows the "Start new Claude sessions through the pool" row.
    static let routingWired = true

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

        /// #1499: the same change as dch 1.94.0 --revive flags: `--unset K` per removal (in order), then `--env K=V` per set
        /// (by key). Only names and the set values go in argv: the pool's set is its loopback URL, never a credential.
        var reviveFlags: [String] {
            remove.flatMap { ["--unset", $0] } + self.set.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
        }
    }

    static func baseURL(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// The program name of a command word the way dch reads it: the text after the last "/", or
    /// the whole word. Not NSString.lastPathComponent, which drops a trailing "/" (QA #726 F1):
    /// "claude/" names no program here.
    static func programName(_ word: String) -> String {
        word.lastIndex(of: "/").map { String(word[word.index(after: $0)...]) } ?? word
    }

    /// `command` is the user's command value (argv) BEFORE any login-shell wrap: the wrapped argv
    /// starts with the shell and would never route (errata C8). Off, the proxy not healthy, or a
    /// pool with no account (QA #739 F1; `CCPoolStore.hasAccounts`): no change at all. `claude` gets ANTHROPIC_BASE_URL
    /// only: OQ-132 keeps the person's API key and tokens in the env (the proxy replaces the client's auth header, S10).
    /// `headroom` is not routed in v1 (#1200): it reads its upstream address in its own proxy process, shared by every
    /// headroom session, so it cannot be set per session; the environment stays as it is, credentials kept. Anything else
    /// (a shell, `direnv exec . claude`, a custom wrapper): no change.
    static func sessionEnv(command: [String], base: String, on: Bool, healthy: Bool, hasAccounts: Bool) -> EnvDelta {
        guard on, healthy, hasAccounts, let first = command.first else { return EnvDelta() }
        switch programName(first) {
        case "claude": return EnvDelta(set: ["ANTHROPIC_BASE_URL": base])
        case "headroom": return EnvDelta()
        default: return EnvDelta()
        }
    }

    /// spec 3.6 at spawn time: the person's toggle, the proxy's status and the pool's accounts, each read
    /// when a session starts. One value feeds both the spawn env (`contributor`) and the New session form's
    /// "via ccpool" hint (AgentNewSession.poolHint), so the two cannot disagree.
    /// Isolation: none; its closures run on the --spawn runner's queue (DispatchQueue.global) and on main.
    struct Routing: Sendable {
        var on: @Sendable () -> Bool
        var status: @Sendable () -> CCPoolService.Status
        var hasAccounts: @Sendable () -> Bool

        /// The toggle is read first: off, neither the status nor the store is read, so turning it off holds
        /// for the next spawn whatever they would say. Only `.running` routes (stopped, held, failed: no).
        func delta(_ argv: [String]) -> EnvDelta {
            guard on(), case .running(let port) = status() else { return EnvDelta() }
            return sessionEnv(command: argv, base: baseURL(port: port), on: true, healthy: true, hasAccounts: hasAccounts())
        }

        /// spec 6.1's ccpool member. Called on the runner's queue, never main. An empty delta returns `env`
        /// unchanged, byte for byte.
        var contributor: SessionEnvContributor { { [self] argv, env in delta(argv).applied(to: env) } }

        /// #1499: the same delta as --revive flags (AgentIslandController.resume, dch 1.94.0); read on the runner's queue too.
        var reviveFlags: ReviveEnvFlags { { [self] argv in delta(argv).reviveFlags } }
    }
}
