import Darwin
import Foundation

/// #1666 (#1664 F4a): one row per pool event, JSON Lines schema v1. Only fixed words, the account label (allowed in this
/// plain file), a claim name, a reset epoch and the session id of a valid pin key: never a token, a header value other
/// than the rate-limit numbers, or a body byte.
struct AgentPoolEventRow: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case bench, rotate, retire
        case throttleMove = "throttle-move"
        case pinBack = "pin-back"
        case allBenched = "all-benched"
    }

    var t: Double
    var ev: Kind
    var acct: String?
    var from: String?
    var to: String?
    /// Written only when it is one of the five fixed claims.
    var claim: String?
    var reset: Int?
    /// Written only when it is a valid pin key.
    var sess: String?

    /// The row as one line (no newline), keys in the schema's order, absent keys omitted; nil when `t` is not a sane epoch.
    func line() -> Data? {
        // Below year 9999, so the day file name always has four digits and matches isOwnName.
        guard t.isFinite, (0..<253402300800).contains(t) else { return nil }
        let q = AgentPoolUsageRow.quote
        var s = "{\"v\":1,\"t\":\(String(format: "%.3f", t)),\"ev\":\(q(ev.rawValue))"
        if let acct { s += ",\"acct\":\(q(acct))" }
        if let from { s += ",\"from\":\(q(from))" }
        if let to { s += ",\"to\":\(q(to))" }
        if let claim, AgentPoolUsageRow.claims.contains(claim) { s += ",\"claim\":\(q(claim))" }
        if let reset { s += ",\"reset\":\(reset)" }
        if let sess, AgentPoolState.validPinKey(sess) { s += ",\"sess\":\(q(sess))" }
        return Data((s + "}").utf8)
    }
}

/// #1666: the day files `events-YYYY-MM-DD.jsonl` (UTC) in their own 0700 folder, files 0600 (spec 3.2, 3.4). A serial
/// queue off the connection queue, buffered: flush at 64 rows, 5 s after the first held row, and at stop. A failed write
/// is one log line and dropped rows; nothing here can delay, change or fail a request.
final class AgentPoolEventRecord: @unchecked Sendable {
    static let rowMax = 2 << 10
    static let dayMax = 16 << 20
    static let folderMax = 512 << 20
    static let keepDays = 35
    static let flushRows = 64
    static let flushSeconds = 5.0

    let directory: URL
    private let log: AgentPoolLogger
    private let queue = DispatchQueue(label: "com.prosper.ccpool.events")
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
    init(directory: URL, logger: AgentPoolLogger, flushDelay: Double = AgentPoolEventRecord.flushSeconds) {
        self.directory = directory
        self.log = logger
        self.flushDelay = flushDelay
    }

    /// The only names this writer ever creates, lists or removes: exactly `events-NNNN-NN-NN.jsonl`.
    static func isOwnName(_ name: String) -> Bool {
        let b = Array(name.utf8)
        guard b.count == 23, name.hasPrefix("events-"), name.hasSuffix(".jsonl"), b[11] == 0x2d, b[14] == 0x2d else { return false }
        return [7, 8, 9, 10, 12, 13, 15, 16].allSatisfy { (0x30...0x39).contains(b[$0]) }
    }

    /// Hand a row over; returns at once.
    func add(_ row: AgentPoolEventRow) {
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

    private func take(_ row: AgentPoolEventRow) {
        guard let line = row.line() else { return log.note(nil, "event row without a usable time; not written") }
        guard line.count <= Self.rowMax else { return log.note(nil, "event row over \(Self.rowMax) bytes; not written") }
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
            return log.note(nil, "event record folder could not be made; \(rows.count) row(s) dropped")
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

    /// Keep 35 days: at the first write of a new day, own files of days at or before today minus 35 go.
    private func removeOld(today: String) {
        guard let date = dayFormat.date(from: today) else { return }
        let cutoff = dayFormat.string(from: date.addingTimeInterval(-Double(Self.keepDays) * 86400))
        for f in ownFiles() where f.name <= "events-\(cutoff).jsonl" {
            if unlink(directory.appendingPathComponent(f.name).path) != 0 { log.note(nil, "an old event file could not be removed") }
        }
    }

    private func append(_ lines: [Data], day: String) {
        let name = "events-\(day).jsonl"
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
                log.note(nil, "an old event file could not be removed")
                break
            }
            total -= old.size
        }
        let fd = open(directory.appendingPathComponent(name).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return log.note(nil, "event record could not be opened; \(kept) row(s) dropped") }
        defer { Darwin.close(fd) }
        // A FIFO or device under an own name is never written (O_NONBLOCK keeps the open from waiting for a reader).
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return log.note(nil, "event record could not be opened; \(kept) row(s) dropped")
        }
        _ = fchmod(fd, 0o600)
        let n = out.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
        if n != out.count { log.note(nil, "event record write failed; \(kept) row(s) dropped") }
    }

    /// One log line per day that dropped rows at its cap.
    private func reportDrops(except day: String?) {
        for (d, n) in dropped.sorted(by: { $0.key < $1.key }) where d != day {
            log.note(nil, "event record for \(d) reached \(Self.dayMax >> 20) MiB; \(n) row(s) dropped")
            dropped[d] = nil
        }
    }
}
