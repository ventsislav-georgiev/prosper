import Darwin
import Foundation

/// #1482 (#1183 R1): one row per relayed reply, JSON Lines schema v1 (spec 3.3). Only counts, fixed words, the
/// account's Keychain id, the validated model and the session id of the pin key: never a token, a label, a header
/// value other than the rate-limit numbers, or a body byte.
struct CCPoolUsageRow: Equatable, Sendable {
    var t: Double
    var acct: String
    var model: String
    /// The session and agent ids of a valid pin key; both nil without one.
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
    var usage: CCPoolTokenUsage?
    var lim: [String: CCPoolLimit]

    /// The fixed five claims, in the order they are written.
    static let claims = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included"]
    static let statuses = ["allowed": "a", "allowed_warning": "w", "rejected": "r"]

    /// `[a-z0-9.-]{1,64}`, else "other".
    static func modelWord(_ m: String?) -> String {
        guard let m, (1...64).contains(m.utf8.count),
              m.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x2d })
        else { return "other" }
        return m
    }

    /// A fixed word, never the query string.
    static func pathWord(_ p: String) -> String {
        switch p.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) {
        case "/v1/messages": return "messages"
        case "/v1/messages/count_tokens": return "count_tokens"
        default: return "other"
        }
    }

    private static func quote(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// The row as one line (no newline), keys in the schema's order; nil when `t` is not a sane epoch.
    func line() -> Data? {
        // Below year 9999, so the day file name always has four digits and matches isOwnName.
        guard t.isFinite, (0..<253402300800).contains(t) else { return nil }
        var s = "{\"v\":1,\"t\":\(String(format: "%.3f", t)),\"acct\":\(Self.quote(acct)),\"model\":\(Self.quote(Self.modelWord(model)))"
        if let sess { s += ",\"sess\":\(Self.quote(sess)),\"agent\":\(Self.quote(agent ?? ""))" }
        s += ",\"path\":\(Self.quote(path)),\"st\":\(st),\"ms\":\(max(0, ms)),\"done\":\(done),\"qc\":\(qc)"
        s += ",\"att\":\(att),\"thr\":\(thr),\"mv\":\(mv),\"routed\":\(Self.quote(routed))"
        if let u = usage {
            // CCPoolUsageTap.count bounds every count to a finite 0...1e12, so Int() cannot trap.
            let n = [u.input, u.output, u.cacheRead, u.cacheWrite5m, u.cacheWrite1h].map { Int($0) }
            s += ",\"in\":\(n[0]),\"out\":\(n[1]),\"cr\":\(n[2]),\"cw5\":\(n[3]),\"cw1\":\(n[4])"
        }
        var parts: [String] = []
        for claim in Self.claims {
            guard let row = lim[claim] else { continue }
            var f: [String] = []
            if let u = CCPoolCore.utils([claim: row])[claim] { f.append("\"u\":\(u)") }
            if let r = CCPoolCore.epoch(row.reset) { f.append("\"r\":\(r)") }
            if let w = row.status.flatMap({ Self.statuses[$0] }) { f.append("\"s\":\"\(w)\"") }
            if !f.isEmpty { parts.append("\"\(claim)\":{\(f.joined(separator: ","))}") }
        }
        if !parts.isEmpty { s += ",\"lim\":{\(parts.joined(separator: ","))}" }
        return Data((s + "}").utf8)
    }
}

/// #1482: the day files `usage-YYYY-MM-DD.jsonl` (UTC) in their own 0700 folder, files 0600 (spec 3.2, 3.4). A serial
/// queue off the connection queue, buffered: flush at 64 rows, 5 s after the first held row, and at stop. A failed write
/// is one log line and dropped rows; nothing here can delay, change or fail a request.
final class CCPoolUsageRecord: @unchecked Sendable {
    static let rowMax = 2 << 10
    static let dayMax = 16 << 20
    static let folderMax = 128 << 20
    static let keepDays = 14
    static let flushRows = 64
    static let flushSeconds = 5.0

    let directory: URL
    private let log: CCPoolLogger
    private let queue = DispatchQueue(label: "com.prosper.ccpool.usage")
    // Everything below is touched on `queue` only.
    private var pending: [(day: String, line: Data)] = []
    private var timerArmed = false
    private var cleanedDay: String?
    private var dropped: [String: Int] = [:]
    private let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let flushDelay: Double

    /// `flushDelay` is a test seam for the 5 s flush.
    init(directory: URL, logger: CCPoolLogger, flushDelay: Double = CCPoolUsageRecord.flushSeconds) {
        self.directory = directory
        self.log = logger
        self.flushDelay = flushDelay
    }

    /// The only names this writer ever creates, lists or removes: exactly `usage-NNNN-NN-NN.jsonl`.
    static func isOwnName(_ name: String) -> Bool {
        let b = Array(name.utf8)
        guard b.count == 22, name.hasPrefix("usage-"), name.hasSuffix(".jsonl"), b[10] == 0x2d, b[13] == 0x2d else { return false }
        return [6, 7, 8, 9, 11, 12, 14, 15].allSatisfy { (0x30...0x39).contains(b[$0]) }
    }

    /// Hand a row over; returns at once.
    func add(_ row: CCPoolUsageRow) {
        queue.async { self.take(row) }
    }

    /// Write what is held now (tests, and stop).
    func flush() { queue.sync { write() } }

    /// Waits until every row handed over so far is taken, without writing (tests).
    func settle() { queue.sync {} }

    /// Stop/quit: write what is held and say how many rows each full day dropped.
    func stop() {
        queue.sync {
            write()
            reportDrops(except: nil)
        }
    }

    private func take(_ row: CCPoolUsageRow) {
        guard let line = row.line() else { return log.note(nil, "usage row without a usable time; not written") }
        guard line.count <= Self.rowMax else { return log.note(nil, "usage row over \(Self.rowMax) bytes; not written") }
        pending.append((dayFormat.string(from: Date(timeIntervalSince1970: row.t)), line))
        if pending.count >= Self.flushRows { return write() }
        if !timerArmed {
            timerArmed = true
            queue.asyncAfter(deadline: .now() + flushDelay) { self.write() }
        }
    }

    private func write() {
        timerArmed = false
        guard !pending.isEmpty else { return }
        let rows = pending
        pending = []
        // Never recreates a missing parent: the folder lives beside state.json or not at all.
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            return log.note(nil, "usage record folder could not be made; \(rows.count) row(s) dropped")
        }
        var days: [String] = []
        for r in rows where !days.contains(r.day) { days.append(r.day) }
        for day in days {
            if cleanedDay.map({ day > $0 }) ?? true {
                cleanedDay = day
                removeOld(today: day)
                reportDrops(except: day)
            }
            let lines = rows.filter { $0.day == day }.map(\.line)
            append(lines, day: day)
        }
    }

    /// Own files sorted by name (oldest day first) with their sizes; a symlink, folder or foreign name is never listed.
    private func ownFiles() -> [(name: String, size: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(Self.isOwnName).sorted().compactMap { name in
            var info = stat()
            guard lstat(directory.appendingPathComponent(name).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return (name, Int(info.st_size))
        }
    }

    /// Keep 14 days: at the first write of a new day, own files of days at or before today minus 14 go.
    private func removeOld(today: String) {
        guard let date = dayFormat.date(from: today) else { return }
        let cutoff = dayFormat.string(from: date.addingTimeInterval(-Double(Self.keepDays) * 86400))
        for f in ownFiles() where f.name <= "usage-\(cutoff).jsonl" {
            if unlink(directory.appendingPathComponent(f.name).path) != 0 { log.note(nil, "an old usage file could not be removed") }
        }
    }

    private func append(_ lines: [Data], day: String) {
        let name = "usage-\(day).jsonl"
        var files = ownFiles()
        let size = files.first { $0.name == name }?.size ?? 0
        var out = Data()
        var kept = 0
        for l in lines where size + out.count + l.count + 1 <= Self.dayMax {
            out.append(l)
            out.append(10)
            kept += 1
        }
        if kept < lines.count { dropped[day, default: 0] += lines.count - kept }
        guard !out.isEmpty else { return }
        // The folder cap: the oldest other day file goes first.
        var total = files.reduce(0) { $0 + $1.size }
        while total + out.count > Self.folderMax, let old = files.first(where: { $0.name != name }) {
            files.removeAll { $0.name == old.name }
            if unlink(directory.appendingPathComponent(old.name).path) != 0 {
                log.note(nil, "an old usage file could not be removed")
                break
            }
            total -= old.size
        }
        let fd = open(directory.appendingPathComponent(name).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return log.note(nil, "usage record could not be opened; \(kept) row(s) dropped") }
        defer { Darwin.close(fd) }
        // A FIFO or device under an own name is never written (O_NONBLOCK keeps the open from waiting for a reader).
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return log.note(nil, "usage record could not be opened; \(kept) row(s) dropped")
        }
        _ = fchmod(fd, 0o600)
        let n = out.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
        if n != out.count { log.note(nil, "usage record write failed; \(kept) row(s) dropped") }
    }

    /// One log line per day that dropped rows at its cap.
    private func reportDrops(except day: String?) {
        for (d, n) in dropped.sorted(by: { $0.key < $1.key }) where d != day {
            log.note(nil, "usage record for \(d) reached \(Self.dayMax >> 20) MiB; \(n) row(s) dropped")
            dropped[d] = nil
        }
    }
}
