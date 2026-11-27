import Foundation

/// #2004 (design #2003, phase 1): what the pool needs from one agent harness. Today Claude is the only one; the
/// listener, socket, pins, place/pick, benches, holds, refusal, usage record and pane stay shared. A connection picks
/// its adapter once per request: nothing here is called per relayed chunk (the usage tap is a value type).
protocol PoolHarness: Sendable {
    /// "claude": the harness id an account carries in state.json (absent there = claude).
    var id: String { get }
    /// The production upstream; tests point `CCPoolServiceConfig.upstream` elsewhere.
    var upstream: URL { get }
    /// Request headers never relayed: hop-by-hop, the proxy's own, and the client's credential.
    var stripRequest: Set<String> { get }
    /// Sets the pool account's credential on a request whose client credential was stripped.
    func authorize(_ req: inout URLRequest, token: String)
    func parseLimits(_ headers: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String])
    func claims(for model: String?) -> [String]
    func isKnownModel(_ model: String?) -> Bool
    var displayOrder: [String] { get }
    var display: [String: String] { get }
    func pinKey(_ head: CCPoolRequestHead) -> String?
    func usageTap(contentType: String?) -> CCPoolUsageTap
    var prices: [(family: String, input: Double, output: Double, read: Double)] { get }
    func isQuotaCheck(_ obj: [String: Any]?) -> Bool
    func probe(token: String, base: URL, timeout: TimeInterval) async -> CCPoolUsage.Probe?
    /// The session env rule: `key` is set to the pool's base URL for these argv[0] program names.
    var env: (key: String, programs: Set<String>) { get }
}

/// Claude Code against api.anthropic.com: the values the pool used before the seam, moved here unchanged. The old
/// names (CCPoolCore.parseLimits, CCPoolConnection.pinKey, ...) forward to the statics below.
struct ClaudeHarness: PoolHarness {
    static let id = "claude"
    static let upstream = URL(string: "https://api.anthropic.com")!

    /// Hop-by-hop headers plus the ones the proxy owns (B10). The client's own credential never
    /// goes upstream. accept-encoding: URLSession decodes what it asked for, so it asks itself.
    static let stripRequest: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                            "te", "trailers", "trailer", "proxy-connection", "transfer-encoding", "upgrade", "host",
                                            "authorization", "x-api-key", "content-length", "expect", "accept-encoding"]

    static let oauthBeta = "oauth-2025-04-20"
    /// #1595: the client's anthropic-beta list with the OAuth beta appended once; a list that already
    /// names it (any case or spacing) goes out unchanged.
    static func withOAuthBeta(_ list: String?) -> String {
        let list = list ?? ""
        let has = list.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(oauthBeta) == .orderedSame
        }
        if has { return list }
        return list.trimmingCharacters(in: .whitespaces).isEmpty ? oauthBeta : list + "," + oauthBeta
    }

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

    /// ccpool_proxy.py:173-174, in the reference's order: (family, input, output, cache read) $/MTok.
    static let prices: [(family: String, input: Double, output: Double, read: Double)] = [
        ("fable", 8, 40, 0.2), ("mythos", 8, 40, 0.2), ("opus", 4, 20, 0.2),
        ("sonnet", 2, 10, 0.1), ("haiku", 0.1, 0.5, 0.01),
    ]

    static let env: (key: String, programs: Set<String>) = ("ANTHROPIC_BASE_URL", ["claude"])

    static let probeModel = "claude-haiku-4-5-20251001"
    static let marker = "You are Claude Code, Anthropic's official CLI for Claude."

    static func claims(for model: String?) -> [String] {
        guard let model else { return mostRestrictive }
        return claimsTable.first { model.contains($0.model) }?.claims ?? mostRestrictive
    }

    static func isKnownModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return claimsTable.contains { model.contains($0.model) }
    }

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

    /// #1256: the client's quota check is a JSON body whose max_tokens is the integer 1 (Python
    /// `req.get("max_tokens") == 1`); a bool, a float, a string or any other value is not one.
    static func isQuotaCheck(_ obj: [String: Any]?) -> Bool {
        guard let n = obj?["max_tokens"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) else { return false }
        return n.int64Value == 1
    }

    /// #1259: the conversation key "<session id>/<agent id>" as Python conversation() builds it (ccpool_proxy.py 83-85),
    /// header names case-insensitive; outside data, so nil unless the whole key passes validPinKey. Never logged.
    static func pinKey(_ head: CCPoolRequestHead) -> String? {
        guard let sid = head.header("x-claude-code-session-id"), !sid.isEmpty else { return nil }
        let key = sid + "/" + (head.header("x-claude-code-agent-id") ?? "")
        return CCPoolState.validPinKey(key) ? key : nil
    }

    /// nil on a network error. A 401/403 comes back as a Probe with that status (spec 3.4: "Token rejected").
    static func probe(token: String, base: URL, model: String = probeModel, timeout: TimeInterval = 30) async -> CCPoolUsage.Probe? {
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
        req.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        // QA #734 INFO-10: never follow a redirect (a 3xx is the answer and reads as "could not
        // answer": no rate-limit headers), so the token reaches no host but `base`.
        let session = CCPoolUpstream.probeSession()
        defer { session.finishTasksAndInvalidate() }
        guard let result = try? await session.data(for: req, delegate: CCPoolNoRedirect()),
              let http = result.1 as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
        return CCPoolUsage.Probe(status: http.statusCode, limits: parseLimits(headers).limits)
    }

    // MARK: PoolHarness (the statics above, per instance)

    var id: String { Self.id }
    var upstream: URL { Self.upstream }
    var stripRequest: Set<String> { Self.stripRequest }
    var displayOrder: [String] { Self.displayOrder }
    var display: [String: String] { Self.display }
    var prices: [(family: String, input: Double, output: Double, read: Double)] { Self.prices }
    var env: (key: String, programs: Set<String>) { Self.env }

    func authorize(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // #1595: an OAuth Bearer without this beta is refused upstream (and the 401 benches the account, #1278).
        req.setValue(Self.withOAuthBeta(req.value(forHTTPHeaderField: "anthropic-beta")), forHTTPHeaderField: "anthropic-beta")
    }
    func parseLimits(_ headers: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String]) { Self.parseLimits(headers) }
    func claims(for model: String?) -> [String] { Self.claims(for: model) }
    func isKnownModel(_ model: String?) -> Bool { Self.isKnownModel(model) }
    func pinKey(_ head: CCPoolRequestHead) -> String? { Self.pinKey(head) }
    func usageTap(contentType: String?) -> CCPoolUsageTap { CCPoolUsageTap(contentType: contentType) }
    func isQuotaCheck(_ obj: [String: Any]?) -> Bool { Self.isQuotaCheck(obj) }
    func probe(token: String, base: URL, timeout: TimeInterval) async -> CCPoolUsage.Probe? {
        await Self.probe(token: token, base: base, timeout: timeout)
    }
}
