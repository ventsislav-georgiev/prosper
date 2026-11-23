import Darwin
import Foundation

/// #1483 (#1183 R2): the usage record's reader (spec 3.5) and the five aggregations of the stats view (spec 3.6), as pure
/// functions over decoded rows. Every row is outside data: one that does not decode is skipped and counted, never fatal.
struct CCPoolUsageEntry: Equatable, Sendable {
    struct Tokens: Equatable, Sendable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite5m: Int
        var cacheWrite1h: Int
        var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
    }
    struct Claim: Equatable, Sendable {
        var u: Double?
        var r: Double?
        var s: String?
    }
    var t: Double
    var acct: String
    var model: String
    var sess: String?
    var agent: String?
    var path: String
    var st: Int
    var ms: Int
    var done: Bool
    var qc: Bool
    var att: Int
    var thr: Int
    var mv: Bool
    var routed: String
    var tokens: Tokens?
    var lim: [String: Claim]
}

enum CCPoolUsageSkip: String, CaseIterable, Sendable {
    case tooLong, notJSON, version, missing, type, number, utilization, epoch
}

enum CCPoolUsageRange: Sendable {
    case hour, day, week, fortnight
    var seconds: Double {
        switch self {
        case .hour: return 3600   // #1899: the limits popover's pace
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .fortnight: return 14 * 86_400
        }
    }
}

struct CCPoolUsageReadResult: Equatable, Sendable {
    /// Rows inside the range, oldest first.
    var rows: [CCPoolUsageEntry] = []
    var skipped: [CCPoolUsageSkip: Int] = [:]
    /// Own day files that were not read (a symlink, a folder, a pipe or one that would not open).
    var filesNotRead = 0
    /// The row cap was reached: later lines were not read.
    var truncated = false
    var skippedTotal: Int { skipped.values.reduce(0, +) }
}

enum CCPoolUsageReader {
    static let lineMax = 4 << 10
    static let rowsMax = 500_000
    /// A count (tokens, ms, status, attempts) above this is not believed; it also keeps every sum far inside Int.
    static let countMax = 1e12
    static let epochMax = 253_402_300_800.0
    static let utilMax = 10.0
    static let stringMax = 256
    private static let kinds = ["in", "out", "cr", "cw5", "cw1"]

    /// Off main. `maxRows` is the cap on lines examined (good or bad); a seam for tests, 500,000 in production.
    static func read(directory: URL, range: CCPoolUsageRange, now: Double, maxRows: Int = rowsMax) async -> CCPoolUsageReadResult {
        await Task.detached { readNow(directory: directory, range: range, now: now, maxRows: maxRows) }.value
    }

    static func readNow(directory: URL, range: CCPoolUsageRange, now: Double, maxRows: Int = rowsMax) -> CCPoolUsageReadResult {
        var result = CCPoolUsageReadResult()
        guard now.isFinite, now >= range.seconds, now < epochMax else { return result }
        let since = now - range.seconds
        let first = "usage-\(dayString(since)).jsonl", last = "usage-\(dayString(now)).jsonl"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { CCPoolUsageRecord.isOwnName($0) && $0 >= first && $0 <= last }.sorted()
        var lines = 0
        for name in names where !result.truncated {
            let path = directory.appendingPathComponent(name).path
            // O_NOFOLLOW: a symlinked day file fails to open. O_NONBLOCK: a pipe with that name cannot hang the open.
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var info = stat()
            guard fd >= 0 else { result.filesNotRead += 1; continue }
            defer { Darwin.close(fd) }
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { result.filesNotRead += 1; continue }
            eachLine(fd: fd) { line in
                if lines >= maxRows { result.truncated = true; return false }
                lines += 1
                switch line.map({ decode($0) }) {
                case nil: result.skipped[.tooLong, default: 0] += 1
                case .success(let e)?: if e.t >= since && e.t <= now { result.rows.append(e) }
                case .failure(let why)?: result.skipped[why.reason, default: 0] += 1
                }
                return true
            }
        }
        result.rows.sort { $0.t < $1.t }
        return result
    }

    /// Calls `body` per non-empty line: its bytes, or nil for a line over `lineMax` (never buffered past the cap).
    /// `body` returns false to stop.
    private static func eachLine(fd: Int32, _ body: (Data?) -> Bool) {
        var cur = Data()
        var over = false
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        func finish() -> Bool {
            defer { cur.removeAll(keepingCapacity: true); over = false }
            if over { return body(nil) }
            return cur.isEmpty ? true : body(cur)
        }
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var start = 0
            while start < n {
                let nl = chunk.withUnsafeBytes { raw -> Int? in
                    memchr(raw.baseAddress! + start, 10, n - start).map { raw.baseAddress!.distance(to: UnsafeRawPointer($0)) }
                }
                let end = nl ?? n
                if !over {
                    if cur.count + (end - start) > lineMax { over = true; cur.removeAll() } else { cur.append(contentsOf: chunk[start..<end]) }
                }
                if nl != nil { if !finish() { return } }
                start = end + 1
            }
        }
        // A last line with no newline is read like any other (a cut one fails to decode and is counted).
        _ = finish()
    }

    struct Bad: Error { var reason: CCPoolUsageSkip }

    private static func fail<T>(_ r: CCPoolUsageSkip) -> Result<T, Bad> { .failure(Bad(reason: r)) }

    /// One line to a row; the first thing wrong decides the reason.
    static func decode(_ line: Data) -> Result<CCPoolUsageEntry, Bad> {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return fail(.notJSON) }
        guard let v = obj["v"] else { return fail(.missing) }
        guard let vn = number(v) else { return fail(.type) }
        guard vn == 1 else { return fail(.version) }
        // Every failure below is thrown as the reason; `try?` is never used on a value that matters.
        do {
            let t = try epoch(obj["t"])
            let acct = try string(obj["acct"], required: true), model = try string(obj["model"], required: true)
            let path = try string(obj["path"], required: true), routed = try string(obj["routed"], required: true)
            let sess = try string(obj["sess"], required: false), agent = try string(obj["agent"], required: false)
            // sess and agent come together or not at all.
            if (sess == nil) != (agent == nil) { throw Bad(reason: .missing) }
            let st = try count(obj["st"], required: true)!, ms = try count(obj["ms"], required: true)!
            let att = try count(obj["att"], required: true)!, thr = try count(obj["thr"], required: true)!
            let done = try bool(obj["done"]), qc = try bool(obj["qc"]), mv = try bool(obj["mv"])
            let n = try kinds.map { try count(obj[$0], required: false) }
            // The five counts come together or not at all.
            if n.contains(where: { $0 == nil }) && n.contains(where: { $0 != nil }) { throw Bad(reason: .missing) }
            let tokens = n[0].map { _ in CCPoolUsageEntry.Tokens(input: n[0]!, output: n[1]!, cacheRead: n[2]!, cacheWrite5m: n[3]!, cacheWrite1h: n[4]!) }
            var lim: [String: CCPoolUsageEntry.Claim] = [:]
            if let l = obj["lim"] {
                guard let d = l as? [String: Any] else { throw Bad(reason: .type) }
                for name in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included"] {
                    guard let c = d[name] else { continue }
                    guard let cd = c as? [String: Any] else { throw Bad(reason: .type) }
                    var claim = CCPoolUsageEntry.Claim()
                    if let u = cd["u"] {
                        guard let x = number(u) else { throw Bad(reason: .type) }
                        guard (0...utilMax).contains(x) else { throw Bad(reason: .utilization) }
                        claim.u = x
                    }
                    if cd["r"] != nil { claim.r = try epoch(cd["r"]) }
                    if let s = cd["s"] {
                        guard let w = s as? String, ["a", "w", "r"].contains(w) else { throw Bad(reason: .type) }
                        claim.s = w
                    }
                    lim[name] = claim
                }
            }
            return .success(CCPoolUsageEntry(t: t, acct: acct!, model: model!, sess: sess, agent: agent, path: path!, st: st, ms: ms,
                                             done: done, qc: qc, att: att, thr: thr, mv: mv, routed: routed!, tokens: tokens, lim: lim))
        } catch let b as Bad {
            return .failure(b)
        } catch {
            return fail(.type)
        }
    }

    /// A JSON number (never a boolean) that is finite.
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    private static func epoch(_ v: Any?) throws -> Double {
        guard let v else { throw Bad(reason: .missing) }
        guard let x = number(v) else { throw Bad(reason: .type) }
        guard x >= 0, x < epochMax else { throw Bad(reason: .epoch) }
        return x
    }

    /// A whole, non-negative number up to `countMax`: wrong type for a fraction, `number` for a negative or huge one.
    private static func count(_ v: Any?, required: Bool) throws -> Int? {
        guard let v else { if required { throw Bad(reason: .missing) } else { return nil } }
        guard let x = number(v), x == x.rounded() else { throw Bad(reason: .type) }
        guard x >= 0, x <= countMax else { throw Bad(reason: .number) }
        return Int(x)
    }

    private static func bool(_ v: Any?) throws -> Bool {
        guard let v else { throw Bad(reason: .missing) }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw Bad(reason: .type) }
        return n.boolValue
    }

    private static func string(_ v: Any?, required: Bool) throws -> String? {
        guard let v else { if required { throw Bad(reason: .missing) } else { return nil } }
        guard let s = v as? String, s.utf8.count <= stringMax, !required || !s.isEmpty else { throw Bad(reason: .type) }
        return s
    }

    /// UTC `YYYY-MM-DD` of an epoch (callers keep it in 0..<epochMax).
    static func dayString(_ t: Double) -> String {
        var secs = time_t(t)
        var tmv = tm()
        gmtime_r(&secs, &tmv)
        return String(format: "%04d-%02d-%02d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday))
    }
}

// MARK: the five aggregations (spec 3.6). Rows come oldest first, as `read` returns them.

struct CCPoolUsageTotals: Equatable, Sendable {
    var input = 0, cacheWrite5m = 0, cacheWrite1h = 0, cacheRead = 0, output = 0
    var requests = 0
    var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
    mutating func add(_ k: CCPoolUsageEntry.Tokens) {
        input += k.input; cacheWrite5m += k.cacheWrite5m; cacheWrite1h += k.cacheWrite1h; cacheRead += k.cacheRead; output += k.output
    }
}

enum CCPoolUsageGroup: Sendable { case account, model, session }

enum CCPoolUsageStats {
    struct Point: Equatable, Sendable { var t: Double; var value: Double }
    struct Marker: Equatable, Sendable { var t: Double; var reset: Double }
    struct UtilizationSeries: Equatable, Sendable {
        var acct: String
        /// "five_hour" or "seven_day".
        var window: String
        var points: [Point]
        var resets: [Marker]
    }

    /// 1. Per (account, window): the plotted value is the running maximum of `u` inside one reset value and starts over when
    /// the reset changes; a marker at the first row of each later reset. A row without both `u` and `r` for the window is
    /// not plotted (no reset to group it under). Quota checks count.
    static func utilization(_ rows: [CCPoolUsageEntry]) -> [UtilizationSeries] {
        struct Key: Hashable { var acct: String; var window: String }
        var out: [Key: UtilizationSeries] = [:]
        var state: [Key: (reset: Double, max: Double)] = [:]
        for row in rows {
            for window in ["five_hour", "seven_day"] {
                guard let c = row.lim[window], let u = c.u, let r = c.r else { continue }
                let key = Key(acct: row.acct, window: window)
                // Appends in place: a copy of the series per row would make this quadratic (#1571 O12).
                let empty = UtilizationSeries(acct: row.acct, window: window, points: [], resets: [])
                if let cur = state[key], cur.reset == r {
                    state[key] = (r, max(cur.max, u))
                } else {
                    if state[key] != nil { out[key, default: empty].resets.append(Marker(t: row.t, reset: r)) }
                    state[key] = (r, u)
                }
                out[key, default: empty].points.append(Point(t: row.t, value: state[key]!.max))
            }
        }
        return out.values.sorted { ($0.acct, $0.window) < ($1.acct, $1.window) }
    }

    /// 2. Tokens by kind per account, model or session; quota checks and rows without usage left out. A row without a
    /// session has no bar in the session grouping.
    static func tokens(_ rows: [CCPoolUsageEntry], by group: CCPoolUsageGroup) -> [(key: String, totals: CCPoolUsageTotals)] {
        var out: [String: CCPoolUsageTotals] = [:]
        for row in rows where !row.qc {
            guard let k = row.tokens else { continue }
            let key: String
            switch group {
            case .account: key = row.acct
            case .model: key = row.model
            case .session: guard let s = row.sess else { continue }; key = s
            }
            out[key, default: CCPoolUsageTotals()].add(k)
            out[key]!.requests += 1
        }
        return out.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    struct CachePoint: Equatable, Sendable {
        var t: Double
        /// cr / (in + cr + cw5 + cw1)
        var rate: Double
        var acct: String
        /// The session's account differs from its previous request's.
        var moved: Bool
    }

    /// 3. Per session, oldest first; quota checks left out (a one-token probe with no cache would plot a 0 % dip and could set `moved`). A row with no usage or an empty denominator is not a point and does not set the
    /// session's previous account.
    static func cacheHitRate(_ rows: [CCPoolUsageEntry]) -> [(sess: String, points: [CachePoint])] {
        var out: [String: [CachePoint]] = [:]
        for row in rows where !row.qc {
            guard let s = row.sess, let k = row.tokens else { continue }
            let denom = k.input + k.cacheRead + k.cacheWrite5m + k.cacheWrite1h
            guard denom > 0 else { continue }
            let prev = out[s]?.last?.acct
            out[s, default: []].append(CachePoint(t: row.t, rate: Double(k.cacheRead) / Double(denom), acct: row.acct, moved: prev != nil && prev != row.acct))
        }
        return out.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    struct SessionSummary: Equatable, Sendable {
        var sess: String
        var totals: CCPoolUsageTotals
        var accounts: [String]
        /// Agent id ("" is the main conversation) with its own totals, biggest first.
        var agents: [(agent: String, totals: CCPoolUsageTotals)]
        static func == (a: Self, b: Self) -> Bool {
            a.sess == b.sess && a.totals == b.totals && a.accounts == b.accounts
                && a.agents.map { $0.agent } == b.agents.map { $0.agent } && a.agents.map { $0.totals } == b.agents.map { $0.totals }
        }
    }

    /// 4. Sessions by total tokens, biggest first (ties by id), at most `limit`; quota checks left out as in 2.
    static func topSessions(_ rows: [CCPoolUsageEntry], limit: Int = 20) -> [SessionSummary] {
        var totals: [String: CCPoolUsageTotals] = [:]
        var accts: [String: Set<String>] = [:]
        var agents: [String: [String: CCPoolUsageTotals]] = [:]
        for row in rows where !row.qc {
            guard let s = row.sess, let k = row.tokens else { continue }
            totals[s, default: CCPoolUsageTotals()].add(k)
            totals[s]!.requests += 1
            accts[s, default: []].insert(row.acct)
            agents[s, default: [:]][row.agent ?? "", default: CCPoolUsageTotals()].add(k)
            agents[s]![row.agent ?? ""]!.requests += 1
        }
        let sorted = totals.sorted { ($1.value.total, $0.key) < ($0.value.total, $1.key) }
        return sorted.prefix(max(0, limit)).map { s, t in
            let a = agents[s, default: [:]].sorted { ($1.value.total, $0.key) < ($0.value.total, $1.key) }.map { ($0.key, $0.value) }
            return SessionSummary(sess: s, totals: t, accounts: (accts[s] ?? []).sorted(), agents: a)
        }
    }

    struct FinishPoint: Equatable, Sendable {
        var model: String
        var day: String
        var median: Double
        var p90: Double
        var count: Int
    }

    /// 5. Per model per UTC day: median (the mean of the middle two for an even count) and 90th percentile (nearest rank)
    /// of `ms`, over `st` 200, `done`, not `qc`.
    static func finishTimes(_ rows: [CCPoolUsageEntry]) -> [FinishPoint] {
        struct Key: Hashable { var model: String; var day: String }
        var groups: [Key: [Int]] = [:]
        for row in rows where row.st == 200 && row.done && !row.qc {
            groups[Key(model: row.model, day: CCPoolUsageReader.dayString(row.t)), default: []].append(row.ms)
        }
        return groups.map { key, list -> FinishPoint in
            let v = list.sorted()
            let mid = v.count / 2
            let median = v.count % 2 == 1 ? Double(v[mid]) : Double(v[mid - 1] + v[mid]) / 2
            let rank = (v.count * 9 + 9) / 10
            return FinishPoint(model: key.model, day: key.day, median: median, p90: Double(v[rank - 1]), count: v.count)
        }.sorted { ($0.model, $0.day) < ($1.model, $1.day) }
    }
}
