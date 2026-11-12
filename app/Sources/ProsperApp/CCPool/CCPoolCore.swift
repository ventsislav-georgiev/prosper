import Foundation

// #871: native ccpool. Pure pool logic ported from the Python ccpool (ccpool.py, ccpool_proxy.py,
// ccpool_watch.py). Value types only, clock passed in; no I/O, no secrets.

/// Persisted pool state (`state.json`). Same shape as the Python ccpool's state (`current`,
/// `accounts.<label>.cooldown`, `accounts.<label>.reset`) so a migration can carry it, plus `order`
/// (pick order = Settings list order) and the per-account Keychain `id`. Never holds a token.
struct CCPoolState: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        /// Opaque Keychain account key (a UUID), so a rename never rewrites the secret.
        var id: String
        /// claim -> epoch until which the claim is spent (a bench or a hold).
        var cooldown: [String: Int] = [:]
        /// claim -> epoch the claim's window rolls over, as last reported by Anthropic.
        var reset: [String: Int] = [:]

        init(id: String, cooldown: [String: Int] = [:], reset: [String: Int] = [:]) {
            self.id = id
            self.cooldown = cooldown
            self.reset = reset
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            cooldown = try c.decodeIfPresent([String: Int].self, forKey: .cooldown) ?? [:]
            reset = try c.decodeIfPresent([String: Int].self, forKey: .reset) ?? [:]
        }
    }

    var current: String?
    var order: [String] = []
    var accounts: [String: Account] = [:]

    init(current: String? = nil, order: [String] = [], accounts: [String: Account] = [:]) {
        self.current = current
        self.order = order
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = try c.decodeIfPresent(String.self, forKey: .current)
        accounts = try c.decodeIfPresent([String: Account].self, forKey: .accounts) ?? [:]
        let saved = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        // Order names every account exactly once; a hand-edited or older file is repaired.
        order = saved.filter { accounts[$0] != nil }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        order += accounts.keys.sorted().filter { !order.contains($0) }
    }
}

/// One claim's rate-limit fields as Anthropic reports them (`anthropic-ratelimit-unified-<abbrev>-*`).
struct CCPoolLimit: Equatable, Sendable {
    var status: String?
    var utilization: String?
    var reset: String?
}

enum CCPoolCore {
    /// Bench when the reported utilization reaches this (Python `EXHAUSTED`, a hidden default).
    static let exhaustedDefault = 1.0
    /// Bench length when a claim is spent but Anthropic gave no reset (Python `UNCONFIRMED_BENCH`).
    static let unconfirmedBench = 900
    /// No bench outlives this (Python `MAX_BENCH`).
    static let maxBench = 8 * 86400
    /// A 429 with nothing spent benches only when Retry-After is longer than this.
    static let longRetryAfter = 3600

    static let fiveHour = "five_hour"

    /// Which claims a model draws on (ccpool_watch.CLAIMS), matched by substring, first hit wins.
    /// fable is seven_day_overage_included, not seven_day_opus.
    static let claimsTable: [(model: String, claims: [String])] = [
        ("opus", ["five_hour", "seven_day", "seven_day_opus"]),
        ("fable", ["five_hour", "seven_day", "seven_day_overage_included"]),
        ("sonnet", ["five_hour", "seven_day", "seven_day_sonnet"]),
        ("haiku", ["five_hour", "seven_day"]),
    ]
    /// Unknown model: it is held back by every claim.
    static let mostRestrictive = ["five_hour", "seven_day", "seven_day_opus",
                                  "seven_day_sonnet", "seven_day_overage_included"]
    /// The claims every model draws on (haiku's): a cooldown on one takes the whole account out.
    static let shared = ["five_hour", "seven_day"]

    static let headerPrefix = "anthropic-ratelimit-unified-"
    /// Header abbreviation -> claim name.
    static let abbrev = ["5h": "five_hour", "7d": "seven_day",
                         "7d-opus": "seven_day_opus", "7d-sonnet": "seven_day_sonnet",
                         "7d-overage-included": "seven_day_overage_included"]
    /// Display names (the binary reads seven_day_overage_included as "Fable 5 limit").
    static let display = ["five_hour": "5h", "seven_day": "week", "seven_day_opus": "opus",
                          "seven_day_sonnet": "sonnet", "seven_day_overage_included": "fable"]
    static let displayOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
                               "seven_day_overage_included"]

    // MARK: Model -> claims

    static func claims(for model: String?) -> [String] {
        guard let model else { return mostRestrictive }
        return claimsTable.first { model.contains($0.model) }?.claims ?? mostRestrictive
    }

    static func isKnownModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return claimsTable.contains { model.contains($0.model) }
    }

    // MARK: Selection

    static func eligible(_ account: CCPoolState.Account?, model: String?, now: Double) -> Bool {
        let cd = account?.cooldown ?? [:]
        return claims(for: model).allSatisfy { Double(cd[$0] ?? 0) <= now }
    }

    /// Cooldown keys no claim list reads: an account benched on one would never be skipped.
    static func unreachableKeys(_ state: CCPoolState) -> Set<String> {
        let readable = Set(claimsTable.flatMap(\.claims) + mostRestrictive)
        return Set(state.accounts.values.flatMap { $0.cooldown.keys }).subtracting(readable)
    }

    /// One account serves everything until it is exhausted, then the next: every switch rewrites the
    /// prompt cache (per organisation). The next is the eligible account whose five-hour window rolls
    /// over soonest; never-measured accounts last; ties by `order`.
    static func pick(_ state: CCPoolState, model: String?, exclude: Set<String>, now: Double) -> String? {
        let names = state.order
        if let current = state.current, names.contains(current), !exclude.contains(current),
           eligible(state.accounts[current], model: model, now: now) {
            return current
        }
        let ready = names.enumerated().filter { !exclude.contains($0.element)
            && eligible(state.accounts[$0.element], model: model, now: now) }
        return ready.min { a, b in
            let ra = resetAt(state.accounts[a.element], fiveHour, now: now)
            let rb = resetAt(state.accounts[b.element], fiveHour, now: now)
            return ra != rb ? ra < rb : a.offset < b.offset
        }?.element
    }

    /// The recorded rollover for `claim`, or +inf when never seen (an unseen window is a full one).
    static func resetAt(_ account: CCPoolState.Account?, _ claim: String, now: Double) -> Double {
        guard let r = account?.reset[claim], Double(r) > now else { return .infinity }
        return Double(r)
    }

    /// Earliest cooldown end among the claims `model` draws on, for the all-benched message.
    static func nextReset(_ state: CCPoolState, model: String?, now: Double) -> Int? {
        let wanted = Set(claims(for: model))
        return state.accounts.values.flatMap { $0.cooldown.filter { wanted.contains($0.key) && Double($0.value) > now }.values }.min()
    }

    // MARK: Header parse

    /// `anthropic-ratelimit-unified-<abbrev>-{status,utilization,reset}` -> claim rows. `overage` and
    /// `fallback` are skipped (overage-status reads "rejected" on a healthy account). An unknown
    /// abbreviation is returned in `unknown`, for a log line; it never benches.
    static func parseLimits(_ headers: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String]) {
        var limits: [String: CCPoolLimit] = [:]
        var unknown: Set<String> = []
        for (rawKey, value) in headers {
            let key = rawKey.lowercased()
            guard key.hasPrefix(headerPrefix) else { continue }
            let rest = key.dropFirst(headerPrefix.count)
            for field in ["status", "utilization", "reset"] where rest.hasSuffix("-" + field) {
                let ab = String(rest.dropLast(field.count + 1))
                if ab.isEmpty || ab == "overage" || ab == "fallback" { continue }
                guard let claim = abbrev[ab] else { unknown.insert(ab); continue }
                var row = limits[claim] ?? CCPoolLimit()
                switch field {
                case "status": row.status = value
                case "utilization": row.utilization = value
                default: row.reset = value
                }
                limits[claim] = row
            }
        }
        return (limits, unknown.sorted())
    }

    /// An epoch from a header value; nil for anything that is not a finite, sane number.
    static func epoch(_ s: String?) -> Int? {
        guard let s, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite, abs(d) < 1e12 else { return nil }
        return Int(d)
    }

    /// {claim: reset epoch} for claims Anthropic itself says are spent. A spent claim with no usable
    /// reset gets the short UNCONFIRMED bench.
    static func exhaustedClaims(_ limits: [String: CCPoolLimit], now: Double,
                                threshold: Double = exhaustedDefault) -> [String: Int] {
        var out: [String: Int] = [:]
        for (claim, row) in limits {
            let util = row.utilization.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let spent = row.status == "rejected" || (util.map { $0 >= threshold } ?? false)
            guard spent else { continue }
            out[claim] = epoch(row.reset) ?? Int(now) + unconfirmedBench
        }
        return out
    }

    static func resets(_ limits: [String: CCPoolLimit]) -> [String: Int] {
        limits.compactMapValues { epoch($0.reset) }
    }

    static func utils(_ limits: [String: CCPoolLimit]) -> [String: Double] {
        limits.compactMapValues { $0.utilization.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    }

    // MARK: Pool headroom (the "All" row)

    struct LiveAccount: Equatable, Sendable {
        var util: [String: Double]
        var reset: [String: Int]
        /// Cooldowns in force (spent or held).
        var spent: [String: Int]
    }

    struct PoolCell: Equatable, Sendable {
        var claim: String
        /// Free share summed over accounts: 1.0 = one whole account's quota.
        var free: Double
        /// The next reset that grows `free`, if any.
        var growsAt: Int?
    }

    /// Refused at `at` only by a cooldown on `claim` itself or on a claim every model shares.
    static func blocked(_ spent: [String: Int], claim: String, at: Double) -> Bool {
        ([claim] + shared).contains { Double(spent[$0] ?? 0) > at }
    }

    static func headroom(_ live: [LiveAccount], claim: String, at: Double) -> Double {
        live.reduce(0) { total, acct in
            guard !blocked(acct.spent, claim: claim, at: at), let u = acct.util[claim] else { return total }
            let used = Double(acct.reset[claim] ?? 0) <= at ? 0 : u
            return total + max(0, 1 - used)
        }
    }

    static func poolCells(_ live: [LiveAccount], now: Double) -> [PoolCell] {
        let claims = Set(live.flatMap { $0.util.keys })
        let moments = Set(live.flatMap { $0.reset.values }.filter { Double($0) > now }).sorted()
        return claims.sorted { (displayOrder.firstIndex(of: $0) ?? 99, $0) < (displayOrder.firstIndex(of: $1) ?? 99, $1) }
            .map { claim in
                let free = headroom(live, claim: claim, at: now)
                let grows = moments.first { headroom(live, claim: claim, at: Double($0)) - free > 0.005 }
                return PoolCell(claim: claim, free: free, growsAt: grows)
            }
    }
}

// MARK: - State transitions

extension CCPoolState {
    /// Bench `claim` until `until`, never past now + 8 days, never shortening an existing bench.
    /// Returns false (no change) for a label that is not in the pool.
    @discardableResult
    mutating func bench(_ label: String, claim: String, until: Int, now: Double) -> Bool {
        guard var acct = accounts[label] else { return false }
        let capped = Int(min(Double(until), now + Double(CCPoolCore.maxBench)))
        acct.cooldown[claim] = max(acct.cooldown[claim] ?? 0, capped)
        accounts[label] = acct
        return true
    }

    /// Remember each claim's rollover so rotation knows which healthy account expires soonest.
    mutating func recordResets(_ label: String, limits: [String: CCPoolLimit], now: Double) {
        let fresh = CCPoolCore.resets(limits).filter { Double($0.value) > now }
        guard !fresh.isEmpty, accounts[label] != nil else { return }
        accounts[label]?.reset = fresh
    }

    mutating func remember(_ label: String) {
        if accounts[label] != nil { current = label }
    }

    /// Hold an account out of rotation by hand: a bench on five_hour, the one claim every model reads.
    @discardableResult
    mutating func hold(_ label: String, hours: Double, now: Double) -> Bool {
        bench(label, claim: CCPoolCore.fiveHour, until: Int(now + hours * 3600), now: now)
    }

    /// Undo benches: one account or all (`label == nil`), one claim or every claim.
    mutating func clear(_ label: String?, claim: String? = nil) {
        for name in label.map({ [$0] }) ?? Array(accounts.keys) where accounts[name] != nil {
            if let claim { accounts[name]?.cooldown.removeValue(forKey: claim) } else { accounts[name]?.cooldown = [:] }
        }
    }
}
