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
        /// P2a: epoch a hand hold ends (Settings "Hold for…"). The hold itself is the five_hour bench;
        /// this only lets Settings say "held" instead of "limited". Absent in the Python shape.
        var held: Int?
        /// #1278: epoch of the first 401 this token got on /v1/messages; while set the account is not routed. Cleared by
        /// a 2xx reply, Release or a new token (a fresh Account). Absent from the file when nil.
        var refused: Int?

        init(id: String, cooldown: [String: Int] = [:], reset: [String: Int] = [:], held: Int? = nil, refused: Int? = nil) {
            self.id = id
            self.cooldown = cooldown
            self.reset = reset
            self.held = held
            self.refused = refused
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            cooldown = try c.decodeIfPresent([String: Int].self, forKey: .cooldown) ?? [:]
            reset = try c.decodeIfPresent([String: Int].self, forKey: .reset) ?? [:]
            held = try c.decodeIfPresent(Int.self, forKey: .held)
            refused = try c.decodeIfPresent(Int.self, forKey: .refused)
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

    var current: String?
    var order: [String] = []
    var accounts: [String: Account] = [:]
    /// Conversation key ("<session id>/<agent id>") -> pin. Saved as "pins": {key: account}, Python's shape.
    var pins: [String: Pin] = [:]
    /// #1260: capacity learned from relayed replies, by Keychain id. Saved as "capacity": {id: numbers} (step B).
    var capacity: [String: CCPoolCapacityState] = [:]

    /// Equal = the same file content (CCPoolStore.mutate writes only on a change). #1260 (R1260-a): a capacity row
    /// counts by its `written` numbers only, so a reply that only adds pending dollars never rewrites the file.
    /// #1261 (R1260-f): and only the rows encode writes, so a row of an id outside the pool rewrites nothing.
    static func == (a: CCPoolState, b: CCPoolState) -> Bool {
        a.current == b.current && a.order == b.order && a.accounts == b.accounts && a.pins == b.pins
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
        current = try c.decodeIfPresent(String.self, forKey: .current)
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
        try c.encodeIfPresent(current, forKey: .current)
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

    /// #1259: the account for a request and the state after (Python choose(), ccpool_proxy.py 114-147). No usable
    /// key: `pick` as today, state untouched. A key: its own pin, then its session's main conversation, then the
    /// session's latest; each only while in `order`, not excluded and eligible. None of them (a new conversation, or
    /// the move after a refusal, its account in `exclude`): `place` (#1261). A request pins (or moves) its key to the
    /// account; a quota check only touches a pin it follows.
    /// `followed` is true when a pin gave the answer (#1259 R1259-a).
    static func route(_ state: CCPoolState, key: String?, quotaCheck: Bool, model: String?,
                      exclude: Set<String>, now: Double) -> (account: String?, state: CCPoolState, followed: Bool) {
        guard let key, CCPoolState.validPinKey(key) else { return (pick(state, model: model, exclude: exclude, now: now), state, false) }
        // Lookups read an expired copy: a lookup alone never changes what the file holds (expired pins leave it
        // with the next pin or move, which expires first).
        var live = state
        live.expirePins(now: now)
        let sid = (key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key) + "/"
        let siblings = live.pins.filter { $0.key.hasPrefix(sid) && $0.key != key }
            .sorted { ($0.key == sid ? 1 : 0, $0.value.seen, $0.value.account) > ($1.key == sid ? 1 : 0, $1.value.seen, $1.value.account) }
            .map(\.value.account)
        let usable = { (n: String) in state.order.contains(n) && state.accounts[n] != nil && !exclude.contains(n)
            && eligible(state.accounts[n], model: model, now: now) }
        // followed: the answer came from a pin, not from `place`; its reply then leaves `current` where it is.
        let pinned = ([live.pins[key]?.account].compactMap { $0 } + siblings).first(where: usable)
        guard let name = pinned ?? place(state, model: model, exclude: exclude, now: now) else { return (nil, state, false) }
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
    /// returned, as in the reference. Ties: the soonest five-hour reset, then `order`.
    static func place(_ state: CCPoolState, model: String?, exclude: Set<String>, now: Double) -> String? {
        var live = state
        live.expirePins(now: now)
        var sessions: [String: Set<Substring>] = [:]   // bounded by the pin cap
        for (key, pin) in live.pins { sessions[pin.account, default: []].insert(key.prefix { $0 != "/" }) }
        let rows = state.order.compactMap { state.accounts[$0].flatMap { state.capacity[$0.id] } }.filter(\.isValid)
        func rank(_ n: String) -> (full: Bool, score: Double) {
            let row = state.accounts[n].flatMap { state.capacity[$0.id] }
            if let row, !row.isValid { return (true, 0) }
            let util = row.flatMap { r in r.reset.map { $0 > now ? r.maxUtilization : 0 } } ?? 0
            let score = (1 - util) * CCPoolCapacity.capacity(of: row, among: rows) / Double((sessions[n]?.count ?? 0) + 1)
            return (util >= 1, score.isFinite && score > 0 ? score : 0)
        }
        let ready = state.order.enumerated().filter { state.accounts[$0.element] != nil && !exclude.contains($0.element)
            && eligible(state.accounts[$0.element], model: model, now: now) }
            .map { (name: $0.element, index: $0.offset, rank: rank($0.element),
                    reset: resetAt(state.accounts[$0.element], fiveHour, now: now)) }
        return ready.min { a, b in
            if a.rank.full != b.rank.full { return !a.rank.full }
            if a.rank.score != b.rank.score { return a.rank.score > b.rank.score }
            return a.reset != b.reset ? a.reset < b.reset : a.index < b.index
        }?.name
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
