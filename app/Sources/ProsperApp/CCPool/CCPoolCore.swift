import Foundation

// #871: native ccpool. Pure pool logic ported from the Python ccpool (ccpool.py, ccpool_proxy.py,
// ccpool_watch.py). Value types only, clock passed in; no I/O, no secrets.

/// Persisted pool state (`state.json`). Same shape as the Python ccpool's state (`current`,
/// `accounts.<label>.cooldown`, `accounts.<label>.reset`) so a migration can carry it, plus `order`
/// (the pool's members; #1838: never a ranking input, ties go by label) and the per-account Keychain `id`. Never holds a token.
struct CCPoolState: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        /// Opaque Keychain account key (a UUID), so a rename never rewrites the secret.
        var id: String
        /// claim -> epoch until which the claim is spent (a bench or a hold).
        var cooldown: [String: Int] = [:]
        /// claim -> epoch the claim's window rolls over, as last reported by Anthropic.
        var reset: [String: Int] = [:]
        /// P2a: epoch a hand hold ends (Settings "Hold for…"). The hold itself is the five_hour bench;
        /// this only lets Settings say "held" instead of "limited". Absent in the Python shape.
        var held: Int?
        /// #1278: epoch of the first 401 this token got on /v1/messages; while set the account is not routed. Cleared by
        /// a 2xx reply, Release or a new token (a fresh Account). Absent from the file when nil.
        var refused: Int?
        /// #2004: the harness this account serves (PoolHarness.id). Absent from the file for claude, so a Claude-only
        /// state.json is written byte for byte as before the key existed.
        var harness: String = ClaudeHarness.id
        /// #2004: the login kind within the harness (a later phase's "codex-chatgpt", "openai-key"); nil (absent) for claude.
        var kind: String?

        init(id: String, cooldown: [String: Int] = [:], reset: [String: Int] = [:], held: Int? = nil, refused: Int? = nil,
             harness: String = ClaudeHarness.id, kind: String? = nil) {
            self.id = id
            self.cooldown = cooldown
            self.reset = reset
            self.held = held
            self.refused = refused
            self.harness = harness
            self.kind = kind
        }

        private enum CodingKeys: String, CodingKey { case id, cooldown, reset, held, refused, harness, kind }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            cooldown = try c.decodeIfPresent([String: Int].self, forKey: .cooldown) ?? [:]
            reset = try c.decodeIfPresent([String: Int].self, forKey: .reset) ?? [:]
            held = try c.decodeIfPresent(Int.self, forKey: .held)
            refused = try c.decodeIfPresent(Int.self, forKey: .refused)
            harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? ClaudeHarness.id
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
        }

        /// The synthesized shape (optionals only when set), plus harness only when it is not claude.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(cooldown, forKey: .cooldown)
            try c.encode(reset, forKey: .reset)
            try c.encodeIfPresent(held, forKey: .held)
            try c.encodeIfPresent(refused, forKey: .refused)
            if harness != ClaudeHarness.id { try c.encode(harness, forKey: .harness) }
            try c.encodeIfPresent(kind, forKey: .kind)
        }
    }

    /// #1258: a conversation pinned to an account (Python `PINS`: key -> (account, last seen)).
    struct Pin: Equatable, Sendable {
        var account: String
        /// Epoch of the last request; never written to the file (Python keeps the mapping only).
        var seen: Double

        /// #1259 (R1258-a): the stamp is not written, so it is not part of ==: a touch never rewrites the file.
        static func == (a: Pin, b: Pin) -> Bool { a.account == b.account }
    }

    /// #2004: harness id -> the account that harness last served from (`remember`; `pick` prefers it).
    var currents: [String: String] = [:]
    /// Claude's current: the file's single legacy "current" key.
    var current: String? {
        get { currents[ClaudeHarness.id] }
        set { currents[ClaudeHarness.id] = newValue }
    }
    var order: [String] = []
    var accounts: [String: Account] = [:]
    /// Conversation key ("<session id>/<agent id>") -> pin. Saved as "pins": {key: account}, Python's shape.
    var pins: [String: Pin] = [:]
    /// #1260: capacity learned from relayed replies, by Keychain id. Saved as "capacity": {id: numbers} (step B).
    var capacity: [String: CCPoolCapacityState] = [:]
    /// #1855: label -> epoch until which `place` ranks it after every other account (it just refused a placement with a
    /// 429 that spent nothing). Memory only: not encoded, not part of ==, so setting it never writes state.json.
    var shunned: [String: Double] = [:]

    /// Equal = the same file content (CCPoolStore.mutate writes only on a change). #1260 (R1260-a): a capacity row
    /// counts by its `written` numbers only, so a reply that only adds pending dollars never rewrites the file.
    /// #1261 (R1260-f): and only the rows encode writes, so a row of an id outside the pool rewrites nothing.
    static func == (a: CCPoolState, b: CCPoolState) -> Bool {
        a.currents == b.currents && a.order == b.order && a.accounts == b.accounts && a.pins == b.pins
            && a.savedCapacity.compactMapValues(\.written) == b.savedCapacity.compactMapValues(\.written)
    }

    /// #1278: the accounts whose token got a 401; routing skips them (CCPoolConnection.attempt).
    var refusedLabels: Set<String> { Set(accounts.filter { $0.value.refused != nil }.keys) }

    /// The capacity rows the file holds: accounts in the pool, sampled, and accepted by the row check (#1261 R1260-g:
    /// a non-finite or out-of-range number is never handed to the encoder, so it cannot fail the whole save).
    var savedCapacity: [String: CCPoolCapacityState] {
        let ids = Set(accounts.values.map(\.id))
        return capacity.filter { ids.contains($0.key) && $0.value.written != nil && $0.value.isValid }
    }

    /// Not named CodingKeys: both coders are written by hand, and Account keeps its own synthesized keys.
    private enum Keys: String, CodingKey { case current, order, accounts, pins, capacity }

    init(current: String? = nil, order: [String] = [], accounts: [String: Account] = [:], pins: [String: Pin] = [:]) {
        self.current = current
        self.order = order
        self.accounts = accounts
        self.pins = pins
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // #2008: a string (the legacy, Claude-only shape) or the per-harness map (see encode); anything else throws.
        if let legacy = try? c.decodeIfPresent(String.self, forKey: .current) {
            current = legacy
        } else {
            currents = try c.decodeIfPresent([String: String].self, forKey: .current) ?? [:]
        }
        accounts = try c.decodeIfPresent([String: Account].self, forKey: .accounts) ?? [:]
        let saved = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        // Order names every account exactly once; a hand-edited or older file is repaired.
        order = saved.filter { accounts[$0] != nil }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        order += accounts.keys.sorted().filter { !order.contains($0) }
        // Outside data: a bad "pins" value or entry is skipped, never a decode failure (the file is not corrupt).
        // The file has no stamp: -1 is "unknown", stamped with the load time by expirePins (Python load_pins).
        let raw = (try? c.decodeIfPresent([String: LenientString].self, forKey: .pins)) ?? nil
        for (key, value) in raw ?? [:] {
            guard let account = value.value, CCPoolState.validPinKey(key), accounts[account] != nil else { continue }
            pins[key] = Pin(account: account, seen: -1)
        }
        capPins()
        // #1260 (R1257-a): outside data too. Absent, null or not a map: empty; a bad row is dropped (Row), as is a row
        // for an id no account holds; the file is never corrupt for it.
        let ids = Set(accounts.values.map(\.id))
        let rows = (try? c.decodeIfPresent([String: CCPoolCapacityState.Row].self, forKey: .capacity)) ?? nil
        for (id, row) in rows ?? [:] where ids.contains(id) { capacity[id] = row.state }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        // #2008 downgrade guard (QA #2004 n1): with a non-Claude account in the file, "current" is written as the
        // per-harness map, always (even empty). A pre-#2004 build decodes "current" as a String only, so the whole file
        // fails to decode there and its store sets it aside (CCPoolStore.init) instead of sending a Codex login as Claude.
        // A Claude-only file keeps the legacy string, byte for byte.
        if accounts.values.contains(where: { $0.harness != ClaudeHarness.id }) {
            try c.encode(currents, forKey: .current)
        } else {
            try c.encodeIfPresent(current, forKey: .current)
        }
        try c.encode(order, forKey: .order)
        try c.encode(accounts, forKey: .accounts)
        // Absent when empty: a file without pins is written exactly as before this key existed.
        if !pins.isEmpty { try c.encode(pins.mapValues(\.account), forKey: .pins) }
        // #1260: numbers only, by Keychain id, only for accounts in the pool and only once sampled; absent when none.
        let saved = savedCapacity
        if !saved.isEmpty { try c.encode(saved, forKey: .capacity) }
    }

    /// A string, or nil for any other JSON value, so one bad pin entry does not fail the map.
    private struct LenientString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
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

    /// Retry-After in seconds, clamped to 0...maxBench before any arithmetic (QA #733 F2): a huge,
    /// negative or non-numeric header cannot trap `now + wait`. Not a number: 0.
    static func retryAfterSeconds(_ raw: String?) -> Int {
        guard let n = Int(raw?.trimmingCharacters(in: .whitespaces) ?? "") else { return 0 }
        return min(max(n, 0), maxBench)
    }

    /// #1256: the waits before the same-account retries of a throughput 429 (Python `BACKOFF`); one retry per step.
    static let throttleBackoff = [1, 2, 4]
    /// A Retry-After this short is the wait instead of the step (Python `0 < wait <= 10`).
    static let throttleRetryAfterMax = 10

    /// The wait in seconds before same-account retry `n` (0-based): the reply's Retry-After when it is
    /// 1...10 s, else the backoff step. Never above 10 s; a bad, zero, negative or long header takes the step.
    static func throttleDelay(retryAfter raw: String?, retry n: Int) -> Int {
        let wait = retryAfterSeconds(raw)
        return (1...throttleRetryAfterMax).contains(wait) ? wait : throttleBackoff[min(max(n, 0), throttleBackoff.count - 1)]
    }

    static let fiveHour = "five_hour"

    /// #2004: Claude's claim tables live in ClaudeHarness; these names forward to them.
    static let claimsTable = ClaudeHarness.claimsTable
    static let mostRestrictive = ClaudeHarness.mostRestrictive
    /// The claims every model draws on (haiku's): a cooldown on one takes the whole account out.
    static let shared = ["five_hour", "seven_day"]

    static let headerPrefix = ClaudeHarness.headerPrefix
    static let abbrev = ClaudeHarness.abbrev
    static let display = ClaudeHarness.display
    static let displayOrder = ClaudeHarness.displayOrder

    // MARK: Model -> claims

    static func claims(for model: String?) -> [String] { ClaudeHarness.claims(for: model) }

    static func isKnownModel(_ model: String?) -> Bool { ClaudeHarness.isKnownModel(model) }

    // MARK: Selection

    static func eligible(_ account: CCPoolState.Account?, model: String?, now: Double,
                         harness: any PoolHarness = ClaudeHarness()) -> Bool {
        let cd = account?.cooldown ?? [:]
        return harness.claims(for: model).allSatisfy { Double(cd[$0] ?? 0) <= now }
    }

    /// #2004: `name` may serve `harness`: its account is of that harness, or (as before the seam) not in `accounts`.
    static func serves(_ state: CCPoolState, _ name: String, _ harness: any PoolHarness) -> Bool {
        (state.accounts[name]?.harness ?? harness.id) == harness.id
    }

    /// Cooldown keys no claim list reads: an account benched on one would never be skipped.
    static func unreachableKeys(_ state: CCPoolState) -> Set<String> {
        let readable = Set(claimsTable.flatMap(\.claims) + mostRestrictive)
        return Set(state.accounts.values.flatMap { $0.cooldown.keys }).subtracting(readable)
    }

    /// One account serves everything until it is exhausted, then the next: every switch rewrites the
    /// prompt cache (per organisation). The next is the eligible account whose five-hour window rolls
    /// over soonest; never-measured accounts last; ties by label (#1838).
    static func pick(_ state: CCPoolState, model: String?, exclude: Set<String>, now: Double,
                     harness: any PoolHarness = ClaudeHarness()) -> String? {
        let names = state.order.filter { serves(state, $0, harness) }
        if let current = state.currents[harness.id], names.contains(current), !exclude.contains(current),
           eligible(state.accounts[current], model: model, now: now, harness: harness) {
            return current
        }
        let ready = names.filter { !exclude.contains($0) && eligible(state.accounts[$0], model: model, now: now, harness: harness) }
        return ready.min { a, b in
            let ra = resetAt(state.accounts[a], fiveHour, now: now)
            let rb = resetAt(state.accounts[b], fiveHour, now: now)
            return ra != rb ? ra < rb : labelFirst(a, b)
        }
    }

    /// #1838: the one label order (the pane's list and every routing tie): Finder-like, case-insensitive; labels it
    /// calls the same ("a", "A") fall back to code points, so the order is total.
    static func labelFirst(_ a: String, _ b: String) -> Bool {
        let c = a.localizedStandardCompare(b)
        return c == .orderedSame ? a < b : c == .orderedAscending
    }

    /// #1259: the account for a request and the state after (Python choose(), ccpool_proxy.py 114-147). No usable
    /// key: `pick` as today, state untouched. A key: its own pin, then its session's main conversation, then the
    /// session's latest; each only while in `order`, not excluded and eligible. None of them (a new conversation, or
    /// the move after a refusal, its account in `exclude`): `place` (#1261). A request pins (or moves) its key to the
    /// account; a quota check only touches a pin it follows.
    /// `followed` is true when a pin gave the answer (#1259 R1259-a). `share` (#1677) only steers `place`; a pin is followed whatever its use.
    static func route(_ state: CCPoolState, key: String?, quotaCheck: Bool, model: String?,
                      exclude: Set<String>, now: Double, share: Double = exhaustedDefault,
                      harness: any PoolHarness = ClaudeHarness()) -> (account: String?, state: CCPoolState, followed: Bool) {
        guard let key, CCPoolState.validPinKey(key) else {
            return (pick(state, model: model, exclude: exclude, now: now, harness: harness), state, false)
        }
        // Lookups read an expired copy: a lookup alone never changes what the file holds (expired pins leave it
        // with the next pin or move, which expires first).
        var live = state
        live.expirePins(now: now)
        let sid = (key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key) + "/"
        let siblings = live.pins.filter { $0.key.hasPrefix(sid) && $0.key != key }
            .sorted { ($0.key == sid ? 1 : 0, $0.value.seen, $0.value.account) > ($1.key == sid ? 1 : 0, $1.value.seen, $1.value.account) }
            .map(\.value.account)
        let usable = { (n: String) in state.order.contains(n) && state.accounts[n]?.harness == harness.id && !exclude.contains(n)
            && eligible(state.accounts[n], model: model, now: now, harness: harness) }
        // followed: the answer came from a pin, not from `place`; its reply then leaves `current` where it is.
        let pinned = ([live.pins[key]?.account].compactMap { $0 } + siblings).first(where: usable)
        guard let name = pinned ?? place(state, model: model, exclude: exclude, now: now, share: share, harness: harness) else {
            return (nil, state, false)
        }
        var st = state
        if live.pins[key]?.account == name {   // the expired copy: an idle pin is never revived by a touch (R1259-q1)
            st.touchPin(key, now: now)   // stamp only: kept in memory, never written (Pin == ignores it)
        } else if !quotaCheck {
            st.expirePins(now: now)
            st.pin(key, to: name, now: now)
        }
        return (name, st, pinned != nil)
    }

    /// #1261: where a new or moving conversation goes (Python place(), ccpool_proxy.py 150-166): among the accounts of
    /// `order` that are in the pool, not excluded and eligible (never wider than `pick`), the highest
    /// (1 - utilization now) x capacity / (live sessions + 1). Utilization now = the saved running max while its
    /// window's reset is after `now`, else 0. Live sessions = distinct session ids pinned to it in an expired copy
    /// (a lookup changes nothing). Learned numbers are outside data: a non-finite or negative score is 0. An account
    /// at or above 100%, or whose row fails the row check, ranks after every other; all there: still one is
    /// returned, as in the reference. Ties: the soonest five-hour reset, then the label (#1838).
    /// #1677: below 1.0, `share` (the pane's "Move off an account at") is a soft preference: an account whose utilization
    /// now is at or above it ranks after every account under it, before the full ones; all over: the order above. It
    /// never excludes, so it never turns an answer into none. At 1.0 (or NaN) no account is over without being full.
    static func place(_ state: CCPoolState, model: String?, exclude: Set<String>, now: Double,
                      share: Double = exhaustedDefault, harness: any PoolHarness = ClaudeHarness()) -> String? {
        var live = state
        live.expirePins(now: now)
        var sessions: [String: Set<Substring>] = [:]   // bounded by the pin cap
        for (key, pin) in live.pins { sessions[pin.account, default: []].insert(key.prefix { $0 != "/" }) }
        let rows = state.order.compactMap { state.accounts[$0].flatMap { state.capacity[$0.id] } }.filter(\.isValid)
        /// tier: 0 under the share, 1 at or over it, 2 full (or a failed row).
        func rank(_ n: String) -> (tier: Int, score: Double) {
            let row = state.accounts[n].flatMap { state.capacity[$0.id] }
            if let row, !row.isValid { return (2, 0) }
            let util = row.flatMap { r in r.reset.map { $0 > now ? r.maxUtilization : 0 } } ?? 0
            let score = (1 - util) * CCPoolCapacity.capacity(of: row, among: rows) / Double((sessions[n]?.count ?? 0) + 1)
            return (util >= 1 ? 2 : util >= share ? 1 : 0, score.isFinite && score > 0 ? score : 0)
        }
        let ready = state.order.filter { state.accounts[$0]?.harness == harness.id && !exclude.contains($0)
            && eligible(state.accounts[$0], model: model, now: now, harness: harness) }
            .map { (name: $0, rank: rank($0), reset: resetAt(state.accounts[$0], fiveHour, now: now),
                    shunned: (state.shunned[$0] ?? 0) > now) }
        return ready.min { a, b in
            // #1855: an account that just refused a placement ranks after every other, full ones included.
            if a.shunned != b.shunned { return !a.shunned }
            if a.rank.tier != b.rank.tier { return a.rank.tier < b.rank.tier }
            if a.rank.score != b.rank.score { return a.rank.score > b.rank.score }
            return a.reset != b.reset ? a.reset < b.reset : labelFirst(a.name, b.name)
        }?.name
    }

    /// #1855: how long `place` ranks an account last after it refused a placement with a 429 that spent nothing: the
    /// reply's Retry-After when it is 1...60 s, else 30 s.
    static func shunSeconds(retryAfter raw: String?) -> Int {
        let wait = retryAfterSeconds(raw)
        return (1...60).contains(wait) ? wait : 30
    }

    /// The recorded rollover for `claim`, or +inf when never seen (an unseen window is a full one).
    static func resetAt(_ account: CCPoolState.Account?, _ claim: String, now: Double) -> Double {
        guard let r = account?.reset[claim], Double(r) > now else { return .infinity }
        return Double(r)
    }

    /// Earliest moment any account serves `model` again: an account serves when its last wanted cooldown ends (the max),
    /// the pool when its first account does (the min). nil when no account has a live wanted cooldown.
    static func nextReset(_ state: CCPoolState, model: String?, now: Double, harness: any PoolHarness = ClaudeHarness()) -> Int? {
        let wanted = Set(harness.claims(for: model))
        return state.accounts.values.filter { $0.harness == harness.id }.compactMap { $0.cooldown.filter { wanted.contains($0.key) && Double($0.value) > now }.values.max() }.min()
    }

    // MARK: Header parse

    /// `anthropic-ratelimit-unified-<abbrev>-{status,utilization,reset}` -> claim rows. `overage` and
    /// `fallback` are skipped (overage-status reads "rejected" on a healthy account). An unknown
    /// abbreviation is returned in `unknown`, for a log line; it never benches.
    static func parseLimits(_ headers: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String]) {
        ClaudeHarness.parseLimits(headers)
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

    /// Utilisation shares from the headers. Anything outside 0...100 (NaN, inf, 1e300) is not a
    /// usage: dropped, so the pane's percent Int() and the pool sum stay in range.
    static func utils(_ limits: [String: CCPoolLimit]) -> [String: Double] {
        limits.compactMapValues { row in
            row.utilization.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { (0...100).contains($0) ? $0 : nil }
        }
    }

    // MARK: Pool headroom (the "All" row)

    struct LiveAccount: Equatable, Sendable {
        var util: [String: Double]
        var reset: [String: Int]
        /// Cooldowns in force (spent or held).
        var spent: [String: Int]
        /// #1907: the epoch of the sample `util` came from; a claim with no reset is used for its window after it.
        var at: Double
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
            // #1907: the island's stale rule: used until its reset, or with no reset for its window after the sample.
            let used = AgentPlanUsage.fresh(claim, util: acct.util, at: acct.at, reset: acct.reset, now: at)?.value ?? 0
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

    /// `label` becomes the current account of its own harness.
    mutating func remember(_ label: String) {
        if let h = accounts[label]?.harness { currents[h] = label }
    }

    /// Hold an account out of rotation by hand: a bench on five_hour, the one claim every model reads.
    /// Non-finite or non-positive hours are refused; a huge value is capped to maxBench before
    /// Int() (QA #734 INFO-8: the pane's custom hold feeds this).
    @discardableResult
    mutating func hold(_ label: String, hours: Double, now: Double) -> Bool {
        guard hours.isFinite, hours > 0 else { return false }
        let seconds = min(hours * 3600, Double(CCPoolCore.maxBench))
        guard bench(label, claim: CCPoolCore.fiveHour, until: Int(now + seconds), now: now) else { return false }
        let until = accounts[label]?.cooldown[CCPoolCore.fiveHour]
        accounts[label]?.held = until
        return true
    }

    // MARK: Pins (#1258; CCPoolCore.route routes by them, #1259)

    /// Python `PIN_IDLE`: a pin idle longer than this is dropped (the longest prompt-cache TTL).
    static let pinIdle: Double = 3600
    /// At most this many pins; the oldest go first.
    static let pinCap = 512
    static let pinKeyMax = 128

    /// A conversation key is outside data: 1...128 printable ASCII characters, no space.
    static func validPinKey(_ key: String) -> Bool {
        let scalars = key.unicodeScalars
        return (1...pinKeyMax).contains(scalars.count) && scalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    /// Drop pins idle more than `pinIdle` (exactly `pinIdle` is kept, as Python's `now - seen > PIN_IDLE`).
    /// A stamp that is not finite, negative (unknown: just loaded) or after `now` (the clock went back) is
    /// set to `now` first: such a pin expires `pinIdle` after this call, never early and never forever.
    mutating func expirePins(now: Double) {
        guard now.isFinite else { return }
        for (key, p) in pins {
            if !p.seen.isFinite || p.seen < 0 || p.seen > now { pins[key]?.seen = now }
        }
        pins = pins.filter { now - $0.value.seen <= CCPoolState.pinIdle }
    }

    /// While over the cap, the oldest pin (ties: the smallest key) is dropped.
    mutating func capPins() {
        guard pins.count > CCPoolState.pinCap else { return }
        let oldest = pins.sorted { ($0.value.seen, $0.key) < ($1.value.seen, $1.key) }.prefix(pins.count - CCPoolState.pinCap)
        for (key, _) in oldest { pins.removeValue(forKey: key) }
    }

    /// Pin `key` to `account`, stamped `now`. False (no change) for a bad key or an account not in the pool.
    @discardableResult
    mutating func pin(_ key: String, to account: String, now: Double) -> Bool {
        guard now.isFinite, now >= 0, CCPoolState.validPinKey(key), accounts[account] != nil else { return false }
        pins[key] = Pin(account: account, seen: now)
        capPins()
        return true
    }

    /// The account `key` is pinned to, after expiry; nil when absent or expired. A pin whose account left the pool is dropped.
    mutating func pinnedAccount(_ key: String, now: Double) -> String? {
        expirePins(now: now)
        guard let account = pins[key]?.account else { return nil }
        guard accounts[account] != nil else { pins.removeValue(forKey: key); return nil }
        return account
    }

    /// #1673: session id -> account label for the live pins, read-only (no expiry written). A key is "<sid>/<agent>"
    /// (first "/" splits it); a sid with several agents shows the main agent's pin (empty agent id), else the most
    /// recently seen (ties: the smaller key). Live = `expirePins`' rule; a pin whose account left the pool is skipped.
    /// QA R1673 n22: at most `sessionLabelsCap` sessions, the most recently seen (ties: the smaller key), so the health
    /// body stays well under the start-up probe's 64 KiB read; a dropped session's status line shows the current account.
    func sessionLabels(now: Double) -> [String: String] {
        guard now.isFinite else { return [:] }
        var best: [String: (rank: Int, seen: Double, key: String, label: String)] = [:]
        for (key, p) in pins where accounts[p.account] != nil {
            let seen = (!p.seen.isFinite || p.seen < 0 || p.seen > now) ? now : p.seen
            guard now - seen <= CCPoolState.pinIdle else { continue }
            let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let sid = String(parts[0])
            let rank = parts.count < 2 || parts[1].isEmpty ? 1 : 0
            if let b = best[sid], !(rank > b.rank || (rank == b.rank && (seen > b.seen || (seen == b.seen && key < b.key)))) { continue }
            best[sid] = (rank, seen, key, p.account)
        }
        guard best.count > CCPoolState.sessionLabelsCap else { return best.mapValues(\.label) }
        let kept = best.sorted { ($0.value.seen, $1.value.key) > ($1.value.seen, $0.value.key) }.prefix(CCPoolState.sessionLabelsCap)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value.label) })
    }
    static let sessionLabelsCap = 64

    /// #1838: live sessions per account for the pane, counted as `place` counts them (distinct session ids pinned to it
    /// after `expirePins`' rule): account -> session ids, read-only. Accounts with none are absent. Bounded by the pin cap.
    func liveSessions(now: Double) -> [String: Set<String>] {
        var live = self
        live.expirePins(now: now)
        var sessions: [String: Set<String>] = [:]
        for (key, pin) in live.pins where accounts[pin.account] != nil {
            sessions[pin.account, default: []].insert(String(key.prefix { $0 != "/" }))
        }
        return sessions
    }

    /// #1855: rank `label` last in `place` for `seconds` from `now` (never shortening a longer one). Expired entries go
    /// first, so the map stays bounded by the labels refused in the last minute. Memory only.
    mutating func shun(_ label: String, seconds: Int, now: Double) {
        guard now.isFinite, accounts[label] != nil else { return }
        shunned = shunned.filter { $0.value > now }
        shunned[label] = max(shunned[label] ?? 0, now + Double(seconds))
    }

    /// Re-stamp a live pin (Python re-pins on every request that follows it).
    mutating func touchPin(_ key: String, now: Double) {
        guard now.isFinite, now >= 0, pins[key] != nil else { return }
        pins[key]?.seen = now
    }

    /// Every pin of a removed account goes with it.
    mutating func unpin(account: String) {
        pins = pins.filter { $0.value.account != account }
    }

    /// Undo benches: one account or all (`label == nil`), one claim or every claim. #1278: every claim (Release) also
    /// puts a refused token back in routing.
    mutating func clear(_ label: String?, claim: String? = nil) {
        for name in label.map({ [$0] }) ?? Array(accounts.keys) where accounts[name] != nil {
            if let claim { accounts[name]?.cooldown.removeValue(forKey: claim) } else { accounts[name]?.cooldown = [:] }
            if claim == nil { accounts[name]?.refused = nil }
            if claim == nil || claim == CCPoolCore.fiveHour { accounts[name]?.held = nil }
        }
    }
}
