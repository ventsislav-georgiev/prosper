import Foundation

/// #871 B20/B21: ask Anthropic directly what an account's quota is. One minimal completion per
/// account, straight to the upstream base (never through ANTHROPIC_BASE_URL), so nothing between
/// can forge a header. For the explicit Refresh only: never polled. No UI wiring in P1.
enum CCPoolUsage {
    static let probeModel = ClaudeHarness.probeModel
    static let marker = ClaudeHarness.marker

    struct Probe: Equatable, Sendable {
        var status: Int
        var limits: [String: CCPoolLimit]
        /// #2010: a Codex account's credits as the pane shows them ("credits $12.50", "unlimited credits"); display only.
        var credits: String? = nil
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
        /// #2010: the probe's credits text (Codex), display only.
        var credits: String? = nil
    }

    struct Report: Equatable, Sendable {
        var rows: [Row]
        var pool: [CCPoolCore.PoolCell]
    }

    /// nil on a network error. A 401/403 comes back as a Probe with that status (spec 3.4: "Token rejected").
    static func probe(token: String, base: URL, model: String = probeModel, timeout: TimeInterval = 30) async -> Probe? {
        await ClaudeHarness.probe(token: token, base: base, model: model, timeout: timeout)
    }

    /// Probe every account in order, bench what the probe says is spent, record rollovers, and
    /// compute the pool headroom row. Costs one call per account.
    static func refresh(store: CCPoolStore, secrets: CCPoolSecrets, base: URL, logger: CCPoolLogger,
                        threshold: Double = CCPoolCore.exhaustedDefault, harness: any PoolHarness = ClaudeHarness()) async -> Report {
        var rows: [Row] = []
        var live: [CCPoolCore.LiveAccount] = []
        // #2004: only this harness's accounts, each through its probe.
        for label in store.read({ st in st.order.filter { (st.accounts[$0]?.harness ?? harness.id) == harness.id } }) {
            guard let id = store.read({ $0.accounts[label]?.id }),
                  let token = (try? secrets.token(id: id)) ?? nil, !token.isEmpty else {
                logger.note(label, "refresh: token unavailable")
                rows.append(Row(label: label, limits: nil, status: nil))
                continue
            }
            let answer = await harness.probe(token: token, id: id, label: label, base: base, timeout: 30, logger: logger)
            // R1190-1: the verdict belongs to the account probed, by its Keychain id, not to its label: a rename, a
            // remove and add or an import Replace during the probe can move the label to another account. An account
            // gone by now gets no row and no write (the pane keys its flags by a row's label).
            guard let named = store.read({ $0.label(ofID: id) }) else {
                logger.note(label, "refresh: account gone during the probe; nothing recorded")
                continue
            }
            // P2a: a 401/403 is a rejected token, said as such (spec 3.4), never a usage reading.
            if let status = answer?.status, status == 401 || status == 403 {
                logger.note(named, "refresh: token rejected (\(status))")
                // #1278: a 401 takes the account out of routing, by its id under the lock (the first stamp kept);
                // a 403 (permission, not the token) stays the pane's display-only verdict and writes nothing.
                let now = store.now
                let marked = status != 401 ? nil : store.mutate { st -> String? in
                    guard let owner = st.label(ofID: id), st.accounts[owner]?.refused == nil,
                          now.isFinite, (0..<1e12).contains(now) else { return nil }
                    st.accounts[owner]?.refused = Int(now)
                    return owner
                }
                if let marked {
                    logger.note(marked, "token rejected (401); not routed until a reply succeeds, Refresh, Release or a new token")
                }
                rows.append(Row(label: named, limits: nil, status: status))
                continue
            }
            guard let p = answer, !p.limits.isEmpty else {
                logger.note(named, "refresh: probe could not answer")
                rows.append(Row(label: named, limits: nil, status: nil))
                continue
            }
            let now = store.now
            let spent = CCPoolCore.exhaustedClaims(p.limits, now: now, threshold: threshold)
            // Resolved again under the store's lock: the writes land on that account or nowhere.
            let owned = store.mutate { st -> (owner: String, cooldown: [String: Int], cleared: Bool)? in
                guard let owner = st.label(ofID: id) else { return nil }
                for (claim, until) in spent { st.bench(owner, claim: claim, until: until, now: now) }
                st.recordResets(owner, limits: p.limits, now: now)
                // #1278: the token answered with its limits, so it works: back in routing.
                let cleared = st.accounts[owner]?.refused != nil
                if cleared { st.accounts[owner]?.refused = nil }
                return (owner, st.accounts[owner]?.cooldown ?? [:], cleared)
            }
            guard let owned else {
                logger.note(named, "refresh: account gone during the probe; nothing recorded")
                continue
            }
            // #1219 (R1205-1): the sample goes to the account by its id, resolved under the lock of the write.
            store.recordUsage(id: id, limits: p.limits)
            if owned.cleared { logger.note(owned.owner, "token accepted again; back in routing") }
            let held = owned.cooldown.filter { Double($0.value) > now && spent[$0.key] == nil }
            logger.note(owned.owner, "refresh: status \(p.status); spent \(spent.keys.sorted()); held \(held.keys.sorted())")
            rows.append(Row(label: owned.owner, limits: p.limits, status: p.status, spent: spent, held: held, credits: p.credits))
            live.append(.init(util: CCPoolCore.utils(p.limits), reset: CCPoolCore.resets(p.limits),
                              spent: spent.merging(held) { a, _ in a }, at: now))
        }
        return Report(rows: rows, pool: CCPoolCore.poolCells(live, now: store.now))
    }

    /// #2010: Refresh for every harness in `runs`, in order, each against its own base; a harness with no account
    /// probes nothing. One report: the rows of all, the pool row of the first harness that has one (two harnesses'
    /// cells share claim names and never add up).
    static func refresh(store: CCPoolStore, secrets: CCPoolSecrets, runs: [(harness: any PoolHarness, base: URL)],
                        logger: CCPoolLogger, threshold: Double = CCPoolCore.exhaustedDefault) async -> Report {
        var all = Report(rows: [], pool: [])
        for run in runs {
            let r = await refresh(store: store, secrets: secrets, base: run.base, logger: logger, threshold: threshold, harness: run.harness)
            all.rows += r.rows
            if all.pool.isEmpty { all.pool = r.pool }
        }
        return all
    }
}
