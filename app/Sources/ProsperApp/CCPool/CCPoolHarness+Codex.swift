import Foundation

/// #2005 (design #2003, phase 2): Codex in ChatGPT mode against chatgpt.com/backend-api/codex, auth and upstream only.
/// A request under `/codex` uses it; Claude stays at the root. #2006 (phase 3): limits, claims, the 429 bench, pins, the
/// usage tap and prices.
struct CCPoolCodexHarness: PoolHarness {
    static let id = "codex"
    /// The one login kind Phase 2 routes (the operator ruled out API-key accounts).
    static let chatgptKind = "codex-chatgpt"
    static let upstream = URL(string: "https://chatgpt.com/backend-api/codex")!
    static let pathPrefix = "/codex"
    /// Today's set plus the client's OpenAI credential and account headers. originator, version, session_id,
    /// OpenAI-Beta and User-Agent pass through untouched.
    static let stripRequest = ClaudeHarness.stripRequest.union(["chatgpt-account-id", "openai-organization", "openai-project", "cookie"])

    /// The path (and query) under the Codex upstream when `path` is `/codex` or under `/codex/` (or `/codex?...`),
    /// else nil: the request is not Codex's.
    static func rest(of path: String) -> String? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let rest = String(path.dropFirst(pathPrefix.count))
        return rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("?") ? rest : nil
    }

    /// The Keychain item of a `codex-chatgpt` account (design section 4); Phase 2 reads only these two fields.
    /// Never logged or described.
    private struct ChatGPTItem: Decodable {
        let access_token: String
        let account_id: String
    }

    /// The default limit id: `x-codex-<slot>-...`. Another id's claims carry its prefix and never bench.
    static let defaultLimit = "codex"
    static let slots = ["primary", "secondary"]
    /// Header field -> its part of a slot. `reset-after-seconds` is from older builds (design section 3).
    static let fields = ["used-percent", "window-minutes", "reset-at", "reset-after-seconds"]
    static let reachedHeader = "x-codex-rate-limit-reached-type"
    /// Both windows are account-wide: every model draws on both.
    static let claimsAll = [CCPoolCore.fiveHour, "seven_day"]
    static let displayOrder = claimsAll
    static let display = [CCPoolCore.fiveHour: "5h", "seven_day": "week"]
    /// The 429 body is read up to this many bytes (only on a 429).
    static let bodyCap = 4096
    /// (family, input, output, cached input) $/MTok, matched by substring, first hit wins; an unknown model takes the
    /// last row. shortcut: list prices as of 2026-11, update when OpenAI changes them
    static let prices: [(family: String, input: Double, output: Double, read: Double)] = [
        ("codex-mini-latest", 1.5, 6, 0.375), ("gpt-5-pro", 15, 120, 15), ("mini", 0.25, 2, 0.025),
        ("nano", 0.05, 0.4, 0.005), ("gpt-5", 1.25, 10, 0.125),
    ]

    /// The claim a window of `minutes` is: 300 five_hour, 10080 seven_day, else `window_<n>m`.
    static func claim(minutes: Int) -> String {
        switch minutes {
        case 300: return CCPoolCore.fiveHour
        case 10080: return "seven_day"
        default: return "window_\(minutes)m"
        }
    }

    /// The pane word of a Codex claim: "5h", "week", `window_<n>m` as "<n/1440>d" or "<n/60>h" (else "<n>m"); a
    /// prefixed claim keeps its limit id ("other.5h"). Anything else is shown as itself.
    static func displayName(_ claim: String) -> String {
        if let dot = claim.lastIndex(of: ".") {
            return String(claim[..<dot]) + "." + displayName(String(claim[claim.index(after: dot)...]))
        }
        if let d = display[claim] { return d }
        guard claim.hasPrefix("window_"), claim.hasSuffix("m"), let n = Int(claim.dropFirst(7).dropLast()), n > 0 else { return claim }
        return n % 1440 == 0 ? "\(n / 1440)d" : n % 60 == 0 ? "\(n / 60)h" : "\(n)m"
    }

    /// A header number: finite and inside `range`, else nil (dropped).
    private static func number(_ s: String?, _ range: ClosedRange<Double>) -> Double? {
        guard let s, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite, range.contains(d) else { return nil }
        return d
    }

    /// `x-<limit id>-{primary,secondary}-{used-percent,window-minutes,reset-at,reset-after-seconds}` -> claim rows,
    /// named by window, never by slot. A value that is not a sane number is dropped; a slot with no usable window
    /// cannot be named and goes to `unknown` ("<id>-<slot>"). Other headers (credits, reached-type) are ignored here.
    static func parseLimits(_ headers: [String: String], now: Double) -> (limits: [String: CCPoolLimit], unknown: [String]) {
        var groups: [String: [String: String]] = [:]   // "<id>-<slot>" -> field -> value
        for (rawKey, value) in headers {
            let key = rawKey.lowercased()
            guard key.hasPrefix("x-") else { continue }
            for slot in Self.slots {
                for field in fields where key.hasSuffix("-\(slot)-\(field)") {
                    let id = key.dropFirst(2).dropLast(slot.count + field.count + 2)
                    if id.isEmpty { continue }
                    groups["\(id)-\(slot)", default: [:]][field] = value
                }
            }
        }
        var limits: [String: CCPoolLimit] = [:]
        var used: [String: (pct: Double, reset: Double)] = [:]
        var unknown: [String] = []
        // Sorted by slot name: at equal use and reset the first name ("primary") stands, whatever the Dictionary order.
        for (name, f) in groups.sorted(by: { $0.key < $1.key }) {
            guard let minutes = number(f["window-minutes"], 1...5_256_000), minutes == minutes.rounded() else {
                unknown.append(name); continue
            }
            let id = String(name.dropLast(name.hasSuffix("-primary") ? 8 : 10))
            let base = Self.claim(minutes: Int(minutes))
            let key = id == defaultLimit ? base : "\(id).\(base)"
            let pct = number(f["used-percent"], 0...1e6)
            let at = number(f["reset-at"], 0...1e11)
                ?? number(f["reset-after-seconds"], 0...1e9).flatMap { a in now.isFinite && (0...1e11).contains(now) ? now + a : nil }
            // Two slots on one window: the fuller one stands, at equal use the later reset (#2025 n4), then the first name.
            if let had = used[key], (had.pct, had.reset) >= (pct ?? -1, at ?? -1) { continue }
            used[key] = (pct ?? -1, at ?? -1)
            var row = CCPoolLimit()
            if let pct {
                row.utilization = "\(pct / 100)"
                row.status = pct >= 100 ? "rejected" : "allowed"
            }
            if let at { row.reset = "\(Int(at))" }
            limits[key] = row
        }
        return (limits, unknown.sorted())
    }

    /// Claims that may bench: the default limit id's only (another id's are recorded and shown, never bench).
    static func benchable(_ limits: [String: CCPoolLimit]) -> [String: CCPoolLimit] {
        limits.filter { !$0.key.contains(".") }
    }

    /// #2006: whether a 429 that the limits did not show as spent still says the account is spent: the reached-type
    /// header, or a body (the first `bodyCap` bytes) whose error.type is usage_limit_reached. Then the reset: the
    /// body's resets_at, its resets_in_seconds, the reset of the fullest default window, else nil (the caller's
    /// fallback). `spent` false: a throttle.
    static func spent429(headers: [String: String], body: Data, now: Double) -> (spent: Bool, reset: Int?) {
        let err = ((try? JSONSerialization.jsonObject(with: body.prefix(bodyCap))) as? [String: Any])?["error"] as? [String: Any]
        let reached = !(headers[reachedHeader]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        guard reached || err?["type"] as? String == "usage_limit_reached" else { return (false, nil) }
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return number(v as? String, 0...1e11) }
            return n.doubleValue.isFinite && (0...1e11).contains(n.doubleValue) ? n.doubleValue : nil
        }
        if let at = num(err?["resets_at"]) { return (true, Int(at)) }
        if let s = num(err?["resets_in_seconds"]), s <= 1e9, now.isFinite, (0...1e11).contains(now) { return (true, Int(now + s)) }
        let limits = benchable(parseLimits(headers, now: now).limits)
        let fullest = limits.max { (Double($0.value.utilization ?? "") ?? -1, $0.key) < (Double($1.value.utilization ?? "") ?? -1, $1.key) }
        return (true, CCPoolCore.epoch(fullest?.value.reset))
    }

    /// #2015: whether a 400 body (its first `bodyCap` bytes) names encrypted content in error.type or error.code. The
    /// exact word is unknown (`invalid_encrypted_content` is not in Codex 0.167.2), so any "encrypted" counts.
    static func encryptedError(_ body: Data) -> Bool {
        guard let err = ((try? JSONSerialization.jsonObject(with: body.prefix(bodyCap))) as? [String: Any])?["error"] as? [String: Any]
        else { return false }
        return ["type", "code"].contains { (err[$0] as? String)?.lowercased().contains("encrypted") == true }
    }

    enum EncryptedStrip: Equatable {
        case stripped(Data, removed: Int, kept: Int)
        /// A compaction item, or an item other than reasoning with encrypted_content: stripping would lose history.
        case blocked
        /// No `input` array or nothing sealed in it.
        case nothing
    }

    /// #2015: the Responses request body without its `reasoning` items that carry encrypted_content (sealed by the
    /// account that made them). The other items keep their order; the rest of the body is unchanged.
    static func stripEncrypted(_ body: Data) -> EncryptedStrip {
        guard var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let input = obj["input"] as? [Any]
        else { return .nothing }
        var kept: [Any] = []
        for item in input {
            let d = item as? [String: Any], type = d?["type"] as? String
            let sealed = d.map { $0["encrypted_content"] != nil && !($0["encrypted_content"] is NSNull) } ?? false
            if type == "compaction" || (sealed && type != "reasoning") { return .blocked }
            if !sealed { kept.append(item) }
        }
        guard kept.count < input.count else { return .nothing }
        obj["input"] = kept
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return .nothing }
        return .stripped(out, removed: input.count - kept.count, kept: kept.count)
    }

    var id: String { Self.id }
    var upstream: URL { Self.upstream }
    var stripRequest: Set<String> { Self.stripRequest }
    var displayOrder: [String] { Self.displayOrder }
    var display: [String: String] { Self.display }
    var prices: [(family: String, input: Double, output: Double, read: Double)] { Self.prices }
    // shortcut: P2 stub, Phase 6 routes codex sessions by argv (design section 9); nothing reads this rule yet
    var env: (key: String, programs: Set<String>) { ("", []) }

    func accepts(kind: String?) -> Bool { kind == Self.chatgptKind }

    /// False (nothing set) for an item that does not decode or lacks either field: the caller skips the account as
    /// it does a missing token, so no empty or raw bearer goes out.
    func authorize(_ req: inout URLRequest, token: String) -> Bool {
        guard let item = try? JSONDecoder().decode(ChatGPTItem.self, from: Data(token.utf8)),
              !item.access_token.isEmpty, !item.account_id.isEmpty else { return false }
        req.setValue("Bearer \(item.access_token)", forHTTPHeaderField: "Authorization")
        req.setValue(item.account_id, forHTTPHeaderField: "chatgpt-account-id")
        return true
    }

    func parseLimits(_ headers: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String]) {
        Self.parseLimits(headers, now: Date().timeIntervalSince1970)
    }
    func claims(for model: String?) -> [String] { Self.claimsAll }
    func isKnownModel(_ model: String?) -> Bool { !(model ?? "").isEmpty }
    /// `codex/<session_id>`, else `codex/<conversation_id>`; outside data, so nil unless the whole key passes
    /// validPinKey. Never logged. `x-codex-turn-state` is the server's stickiness header, relayed, never a key.
    func pinKey(_ head: CCPoolRequestHead) -> String? {
        guard let sid = [head.header("session_id"), head.header("conversation_id")].compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        let key = "codex/" + sid
        return CCPoolState.validPinKey(key) ? key : nil
    }
    func usageTap(contentType: String?) -> CCPoolUsageTap { CCPoolUsageTap(contentType: contentType, codex: true) }
    /// Codex sends no quota check.
    func isQuotaCheck(_ obj: [String: Any]?) -> Bool { false }
    // shortcut: P2 stub, Phase 7 adds the wham/usage probe
    func probe(token: String, base: URL, timeout: TimeInterval) async -> CCPoolUsage.Probe? { nil }
}
