import Foundation

// #1257: capacity learning of the Python ccpool 1.9.0 (ccpool_proxy.py 169-226) as pure functions.
// No file, clock, network, singleton or log. Numbers come from an upstream reply: a bad one skips the step.

/// One response's token counts (already resolved from the reply: cache writes split by lifetime).
struct CCPoolTokenUsage: Equatable, Sendable {
    var input: Double = 0
    var output: Double = 0
    var cacheRead: Double = 0
    /// 5-minute cache writes (also the unsplit `cache_creation_input_tokens`).
    var cacheWrite5m: Double = 0
    var cacheWrite1h: Double = 0
}

/// What one account has learned: dollars of list-price spend per point of five-hour utilization.
/// Numbers only, so the pool's state file can keep it.
struct CCPoolCapacityState: Codable, Equatable, Sendable {
    /// The window's reset stamp the running max belongs to (nil before the first sample).
    var reset: Double?
    /// The window's running maximum utilization.
    var maxUtilization: Double = 0
    /// Dollars spent since the running max last rose.
    var pendingDollars: Double = 0
    /// Learned totals over all counted rises.
    var dollars: Double = 0
    var points: Double = 0
}

extension CCPoolCapacityState {
    /// #1260 step B (R1260-a): the numbers whose change rewrites the state file. The pending dollars change on every
    /// learned reply and are left out: they ride along with the next write. nil before the first sample (not written).
    var written: [Double]? { reset.map { [$0, maxUtilization, dollars, points] } }

    /// A state-file row is outside data (R1257-a): checked as it decodes, nil when bad, so one bad row never fails the file.
    struct Row: Decodable {
        let state: CCPoolCapacityState?
        init(from decoder: Decoder) throws { state = CCPoolCapacityState.checked(decoder) }
    }

    private struct Field: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    /// The row's fields, in this order, exactly (the synthesized coder's names).
    static let fields = ["reset", "maxUtilization", "pendingDollars", "dollars", "points"]

    /// Exactly the five fields; each a JSON number (decode(Double) refuses a string, a bool, a null), finite,
    /// 0...CCPoolCapacity.maxTokens; the running max at most CCPoolCapacity.maxUtilization. Anything else: nil.
    static func checked(_ decoder: Decoder) -> CCPoolCapacityState? {
        guard let c = try? decoder.container(keyedBy: Field.self),
              c.allKeys.count == fields.count, Set(c.allKeys.map(\.stringValue)) == Set(fields) else { return nil }
        var v: [Double] = []
        for name in fields {
            guard let d = try? c.decode(Double.self, forKey: Field(stringValue: name)) else { return nil }
            v.append(d)
        }
        guard v.count == 5 else { return nil }
        let s = CCPoolCapacityState(reset: v[0], maxUtilization: v[1], pendingDollars: v[2], dollars: v[3], points: v[4])
        return s.isValid ? s : nil
    }

    /// #1261 (R1260-g, R1260-q1): what a capacity row may hold, on read (checked) and on write (encode): every number
    /// finite and 0...CCPoolCapacity.maxTokens, the running max at most CCPoolCapacity.maxUtilization.
    var isValid: Bool {
        [reset ?? 0, maxUtilization, pendingDollars, dollars, points].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= CCPoolCapacity.maxTokens }
            && maxUtilization <= CCPoolCapacity.maxUtilization
    }
}

enum CCPoolCapacity {
    /// ccpool_proxy.py:177: below this many points an account's estimate is noise.
    static let minPoints = 0.05
    /// A token count above this is absurd (one response, 1e12 tokens).
    static let maxTokens = 1e12
    /// Utilization is a fraction (0.10 = 10 points); above this it is absurd.
    static let maxUtilization = 10.0

    /// #2004: Claude's price table lives in ClaudeHarness.
    static let prices = ClaudeHarness.prices

    private static func okCount(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= maxTokens }

    /// List-price dollars of one response, or nil when a count is negative, non-finite or absurd.
    /// An unknown or missing model is priced as opus (:181). Overflow: five counts <= 1e12, each times
    /// a factor <= 40 (cache writes at most 8 x 2), five terms: the sum stays below 1e14, far inside Double.
    static func dollars(model: String?, usage u: CCPoolTokenUsage) -> Double? {
        guard okCount(u.input), okCount(u.output), okCount(u.cacheRead),
              okCount(u.cacheWrite5m), okCount(u.cacheWrite1h) else { return nil }
        let p = model.flatMap { m in prices.first { m.contains($0.family) } }
            ?? prices.first { $0.family == "opus" }!
        let plain: Double = u.input * p.input
        let w5: Double = u.cacheWrite5m * p.input * 1.25
        let w1: Double = u.cacheWrite1h * p.input * 2
        let read: Double = u.cacheRead * p.read
        let out: Double = u.output * p.output
        return (plain + w5 + w1 + read + out) / 1e6
    }

    /// The learn step (:191-212). `utilization` and `reset` are the window's five-hour fields after the
    /// response; `usage` nil counts no dollars. A bad number returns the state unchanged.
    static func learn(_ state: CCPoolCapacityState, model: String?, usage: CCPoolTokenUsage?,
                      utilization: Double, reset: Double) -> CCPoolCapacityState {
        guard utilization.isFinite, utilization >= 0, utilization <= maxUtilization,
              reset.isFinite, reset >= 0 else { return state }
        var spent = 0.0
        if let usage {
            guard let d = dollars(model: model, usage: usage) else { return state }
            spent = d
        }
        var s = state
        guard let r = s.reset, r == reset else {
            // A new window starts over and counts nothing; the learned totals stay.
            s.reset = reset; s.maxUtilization = utilization; s.pendingDollars = 0
            return s
        }
        s.pendingDollars += spent
        if utilization > s.maxUtilization {
            s.dollars += s.pendingDollars
            s.points += utilization - s.maxUtilization
            s.maxUtilization = utilization
            s.pendingDollars = 0
        }
        return s
    }

    /// The capacity read (:220-226): the account's own dollars per point when it has at least
    /// `minPoints`, else the median of the accounts that have (upper median for an even count), else 1.0.
    /// `all` holds every account's state, the asked one included.
    static func capacity(of own: CCPoolCapacityState?, among all: [CCPoolCapacityState]) -> Double {
        if let o = own, o.points >= minPoints, o.points.isFinite, o.dollars.isFinite {
            let v = o.dollars / o.points
            if v.isFinite { return v }
        }
        let known = all.filter { $0.points >= minPoints && $0.points.isFinite && $0.dollars.isFinite }
            .map { $0.dollars / $0.points }.filter { $0.isFinite }.sorted()
        return known.isEmpty ? 1.0 : known[known.count / 2]
    }
}
