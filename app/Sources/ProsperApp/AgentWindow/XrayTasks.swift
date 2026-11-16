import Foundation

/// X-ray's version gate: the tabs read `dch --xray <n> --tasks --json`, which dch 1.78.0 added.
enum XrayTabs {
    static let minimumDch = [1, 78, 0]

    /// The one compare the tree uses (DchCommand.gate); no master is consulted, the host's answer decides for a remote.
    static func gate(_ dch: DchCommand.Binary?) -> DchCommand.Gate {
        DchCommand.gate(dch, masters: [], minimum: minimumDch)
    }
}

/// One session's task list as dch prints it (NDJSON: a header, task rows, a done line). Every string is outside data.
struct XrayTasks: Equatable {
    enum Status: String, Equatable { case active, pending, done, dropped }

    struct Task: Equatable {
        var id: String
        var title: String
        var status: Status
        /// The source's own word (in_progress, PARKED ...), kept when the status was one Prosper does not know.
        var label: String
        var active: String?
        var note: String?
        var created: Date?
        var updated: Date?
        var chapter: String?          // an anchor: checked by DchCtl.anchorOK before any use, never shown
        var createdChapter: String?
        var blockedBy: [String]
        var url: String?              // not opened here; a later phase accepts http/https only
        var group: String?
    }

    struct Group: Equatable {
        var title: String
        var tasks: [Task]
    }

    var source: String?
    var sessionTitle: String?
    /// The header's partial flag, or no done line (the output was cut).
    var partial: Bool
    var headerWarn: String?
    var doneWarn: String?
    /// dch's own dropped count from the done line.
    var droppedCount: Int
    /// Lines left out here: over 64 KB, past 50000 rows, or not valid JSON for any line kind.
    var skippedLines: Int
    var tasks: [Task]

    static let maxLine = 64 * 1024
    static let maxRows = 50_000

    /// Count = open tasks, active + pending (dch's own rule).
    var open: Int { tasks.filter { $0.status == .active || $0.status == .pending }.count }

    /// In progress, Pending, Done (newest first), Dropped only when any.
    var groups: [Group] {
        func of(_ s: Status) -> [Task] { tasks.filter { $0.status == s } }
        let done = of(.done).enumerated().sorted { a, b in
            switch (a.element.updated ?? a.element.created, b.element.updated ?? b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        var out = [Group(title: "In progress", tasks: of(.active)), Group(title: "Pending", tasks: of(.pending)),
                   Group(title: "Done", tasks: done)]
        if !of(.dropped).isEmpty { out.append(Group(title: "Dropped", tasks: of(.dropped))) }
        return out
    }

    // MARK: wire

    private struct Header: Decodable {
        let schema: Int
        let source: String?
        let title: String?
        let partial: Bool?
        let warn: String?
    }

    private struct Row: Decodable {
        struct T: Decodable {
            let id: String?
            let title: String?
            let status: String?
            let label: String?
            let active: String?
            let note: String?
            let created: String?
            let updated: String?
            let chapter: String?
            let created_chapter: String?
            let blocked_by: [String]?
            let url: String?
            let group: String?
        }
        let task: T
    }

    private struct DoneLine: Decodable {
        let done: Bool
        let count: Int?
        let dropped: Int?
        let warn: String?
    }

    // Built once: parse runs per poll and a row has two dates. Tried in this order.
    nonisolated(unsafe) private static let isoFormatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    private static func date(_ s: String?) -> Date? {   // a non-ISO value reads as null
        guard let s else { return nil }
        for f in isoFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    private static func task(_ t: Row.T) -> Task {
        let label = OutsideText.shown(t.label ?? "", max: 40)
        return Task(id: OutsideText.shown(t.id ?? "", max: 32), title: OutsideText.shown(t.title ?? "", max: 120),
                    status: Status(rawValue: t.status ?? "") ?? .pending, label: label,
                    active: t.active.map { OutsideText.shown($0, max: 120) }, note: t.note.map { OutsideText.shown($0, max: 120) },
                    created: date(t.created), updated: date(t.updated), chapter: t.chapter, createdChapter: t.created_chapter,
                    blockedBy: (t.blocked_by ?? []).map { OutsideText.shown($0, max: 32) },
                    url: t.url.map { OutsideText.shown($0, max: 2048) }, group: t.group.map { OutsideText.shown($0, max: 120) })
    }

    /// The parse: bytes in, never throws; a bad line is counted and skipped.
    static func parse(_ data: Data) -> XrayTasks {
        var r = XrayTasks(source: nil, sessionTitle: nil, partial: true, headerWarn: nil, doneWarn: nil, droppedCount: 0,
                          skippedLines: 0, tasks: [])
        var sawDone = false, headerPartial = false, rows = 0
        let dec = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.count > maxLine { r.skippedLines += 1; continue }
            if let row = try? dec.decode(Row.self, from: line) {
                rows += 1
                if rows > maxRows { r.skippedLines += 1 } else { r.tasks.append(task(row.task)) }
            } else if let d = try? dec.decode(DoneLine.self, from: line), d.done {
                sawDone = true
                r.droppedCount = max(0, d.dropped ?? 0)
                r.doneWarn = d.warn.map { OutsideText.shown($0, max: 160) }
            } else if let h = try? dec.decode(Header.self, from: line) {
                r.source = h.source.map { OutsideText.shown($0, max: 40) }
                r.sessionTitle = h.title.map { OutsideText.shown($0, max: 120) }
                headerPartial = h.partial ?? false
                r.headerWarn = h.warn.map { OutsideText.shown($0, max: 160) }
            } else { r.skippedLines += 1 }
        }
        r.partial = headerPartial || !sawDone
        return r
    }
}
