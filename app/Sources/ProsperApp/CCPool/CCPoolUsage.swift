import Foundation

/// #871 B20/B21: ask Anthropic directly what an account's quota is. One minimal completion per
/// account, straight to the upstream base (never through ANTHROPIC_BASE_URL), so nothing between
/// can forge a header. For the explicit Refresh only: never polled. No UI wiring in P1.
enum CCPoolUsage {
    static let probeModel = "claude-haiku-4-5-20251001"
    static let marker = "You are Claude Code, Anthropic's official CLI for Claude."

    struct Probe: Equatable, Sendable {
        var status: Int
        var limits: [String: CCPoolLimit]
    }

    struct Row: Equatable, Sendable {
        var label: String
        /// nil: the probe could not answer (network error, or no rate-limit headers), never "healthy".
        var limits: [String: CCPoolLimit]?
        var status: Int?
        /// Claims the probe found spent (now benched).
        var spent: [String: Int] = [:]
        /// Cooldowns still in force that the probe cannot see (holds, long Retry-After benches).
        var held: [String: Int] = [:]
    }

    struct Report: Equatable, Sendable {
        var rows: [Row]
        var pool: [CCPoolCore.PoolCell]
    }

    /// nil on a network error. A 401/403 comes back as a Probe with that status (spec 3.4: "Token rejected").
    static func probe(token: String, base: URL, model: String = probeModel, timeout: TimeInterval = 30) async -> Probe? {
        let payload: [String: Any] = [
            "model": model, "max_tokens": 1,
            "system": [["type": "text", "text": marker, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": "hi"]],
        ]
        // N4: under XCTest the production upstream is never dialled, so no token can leave in a test.
        guard !CCPoolService.refusesUnderTest(base),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("v1/messages"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // QA #734 INFO-10: never follow a redirect (a 3xx is the answer and reads as "could not
        // answer": no rate-limit headers), so the token reaches no host but `base`.
        let session = CCPoolUpstream.probeSession()
        defer { session.finishTasksAndInvalidate() }
        guard let result = try? await session.data(for: req, delegate: CCPoolNoRedirect()),
              let http = result.1 as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
        return Probe(status: http.statusCode, limits: CCPoolCore.parseLimits(headers).limits)
    }

    /// Probe every account in order, bench what the probe says is spent, record rollovers, and
    /// compute the pool headroom row. Costs one call per account.
    static func refresh(store: CCPoolStore, secrets: CCPoolSecrets, base: URL, logger: CCPoolLogger,
                        threshold: Double = CCPoolCore.exhaustedDefault) async -> Report {
        var rows: [Row] = []
        var live: [CCPoolCore.LiveAccount] = []
        for label in store.read({ $0.order }) {
            guard let id = store.read({ $0.accounts[label]?.id }),
                  let token = (try? secrets.token(id: id)) ?? nil, !token.isEmpty else {
                logger.note(label, "refresh: token unavailable")
                rows.append(Row(label: label, limits: nil, status: nil))
                continue
            }
            let answer = await probe(token: token, base: base)
            // P2a: a 401/403 is a rejected token, said as such (spec 3.4), never a usage reading.
            if let status = answer?.status, status == 401 || status == 403 {
                logger.note(label, "refresh: token rejected (\(status))")
                rows.append(Row(label: label, limits: nil, status: status))
                continue
            }
            guard let p = answer, !p.limits.isEmpty else {
                logger.note(label, "refresh: probe could not answer")
                rows.append(Row(label: label, limits: nil, status: nil))
                continue
            }
            let now = store.now
            let spent = CCPoolCore.exhaustedClaims(p.limits, now: now, threshold: threshold)
            let cooldown = store.mutate { st -> [String: Int] in
                for (claim, until) in spent { st.bench(label, claim: claim, until: until, now: now) }
                st.recordResets(label, limits: p.limits, now: now)
                return st.accounts[label]?.cooldown ?? [:]
            }
            store.recordUsage(label, limits: p.limits)
            let held = cooldown.filter { Double($0.value) > now && spent[$0.key] == nil }
            logger.note(label, "refresh: status \(p.status); spent \(spent.keys.sorted()); held \(held.keys.sorted())")
            rows.append(Row(label: label, limits: p.limits, status: p.status, spent: spent, held: held))
            live.append(.init(util: CCPoolCore.utils(p.limits), reset: CCPoolCore.resets(p.limits),
                              spent: spent.merging(held) { a, _ in a }))
        }
        return Report(rows: rows, pool: CCPoolCore.poolCells(live, now: store.now))
    }
}
