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
        var url: String?              // display form (cleaned, capped): shown, never opened
        /// #1351 (QA R1349-i1): the url as dch sent it, the one Open checks (http/https only) and opens.
        var rawURL: String?
        var group: String?
        /// #2024 (dch 1.189.0): an OPEN question's suggested answers (at most 8) and recommendation, shown (60 visible
        /// characters on a chip, the whole in the field); the asker is a session name, compared only, never shown or run.
        var options: [String] = []
        var recommended: String? = nil
        var asker: String? = nil
    }

    struct Group: Equatable {
        var title: String
        var tasks: [Task]
    }

    /// #1351 (QA R1349-i2): the header's schema; the panel has a Tasks tab only for 1. nil: no header.
    var schema: Int?
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
    /// #2024: the --questions header's "answer":true (an answer_command is set where the read ran); absent: false.
    var answerable = false

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

    /// #1974: a questions list (dch --questions): Open (active and pending) first, then Answered (done, newest first),
    /// Dropped only when any.
    var questionGroups: [Group] {
        let g = groups   // always In progress, Pending, Done, then Dropped when any
        return [Group(title: "Open", tasks: g[0].tasks + g[1].tasks), Group(title: "Answered", tasks: g[2].tasks)] + g.dropFirst(3)
    }

    // MARK: wire

    private struct Header: Decodable {
        let schema: Int
        let source: String?
        let title: String?
        let partial: Bool?
        let warn: String?
        let answer: Bool?   // #2024
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
            let options: [String]?   // #2024 (dch 1.189.0, OPEN rows only)
            let recommended: String?
            let asker: String?
        }
        // #1974: a questions read's rows say "question" where a tasks read's say "task" (the same fields)
        let task: T?
        let question: T?
    }

    private struct DoneLine: Decodable {
        let done: Bool
        let count: Int?
        let dropped: Int?
        let warn: String?
    }

    // Built once and shared: parse runs per poll and a row has two dates. A Sendable value, not an
    // ISO8601DateFormatter (not documented thread-safe; Tasks and Questions now parse at once, off main). "+02:00" needs .colon.
    private static let plainISO = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)
    private static let fractionalISO = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)

    static func date(_ s: String?) -> Date? {   // a non-ISO value reads as null
        guard let s else { return nil }
        // #1787: one formatter per date: only a fractional form has a '.', and each formatter reads only its own form
        return try? (s.contains(".") ? fractionalISO : plainISO).parse(s)
    }

    /// #1787: a follow's parsed rows by their line bytes, from its last parse (rows no longer sent drop out), so a build
    /// decodes and dates only the rows that changed. `parses`: rows decoded so far (each one task's date parse).
    struct Cache {
        var rows: [Data: Task] = [:]
        var parses = 0
    }

    private static func task(_ t: Row.T) -> Task {
        let label = OutsideText.shown(t.label ?? "", max: 40)
        return Task(id: OutsideText.shown(t.id ?? "", max: 32), title: OutsideText.shown(t.title ?? "", max: 120),
                    status: Status(rawValue: t.status ?? "") ?? .pending, label: label,
                    active: t.active.map { OutsideText.shown($0, max: 120) }, note: t.note.map { OutsideText.shown($0, max: 120) },
                    created: date(t.created), updated: date(t.updated), chapter: t.chapter, createdChapter: t.created_chapter,
                    blockedBy: (t.blocked_by ?? []).map { OutsideText.shown($0, max: 32) },
                    url: t.url.map { OutsideText.shown($0, max: 2048) }, rawURL: t.url, group: t.group.map { OutsideText.shown($0, max: 120) },
                    // #2024: dch cuts each at 300 bytes; the same cap here (an older or other source may not)
                    options: (t.options ?? []).prefix(8).map { OutsideText.shown($0, max: 300) }.filter { !$0.isEmpty },
                    recommended: t.recommended.map { OutsideText.shown($0, max: 300) }.flatMap { $0.isEmpty ? nil : $0 },
                    asker: t.asker.flatMap { $0.utf8.count <= 64 ? $0 : nil })
    }

    /// The parse: bytes in, never throws; a bad line is counted and skipped.
    static func parse(_ data: Data) -> XrayTasks {
        var cache = Cache()
        return parse(data.split(separator: 0x0A, omittingEmptySubsequences: true), reusing: &cache)
    }

    /// #1787: the same parse over the lines in hand; a row line byte-equal to one in `cache` is not decoded again.
    static func parse(_ lines: [Data], reusing cache: inout Cache) -> XrayTasks {
        var kept: [Data: Task] = [:]
        defer { cache.rows = kept }
        var r = XrayTasks(schema: nil, source: nil, sessionTitle: nil, partial: true, headerWarn: nil, doneWarn: nil, droppedCount: 0,
                          skippedLines: 0, tasks: [])
        var sawDone = false, headerPartial = false, rows = 0
        let dec = JSONDecoder()
        func add(_ row: Row.T, _ line: Data) {
            rows += 1
            if rows > maxRows { r.skippedLines += 1 } else {
                let t = task(row)
                cache.parses &+= 1   // a counter only: wrapping is harmless
                r.tasks.append(t); kept[line] = t
            }
        }
        for line in lines where !line.isEmpty {
            if line.count > maxLine { r.skippedLines += 1; continue }
            if let t = kept[line] ?? cache.rows[line] {
                rows += 1
                if rows > maxRows { r.skippedLines += 1 } else { r.tasks.append(t); kept[line] = t }
            } else if let row = try? dec.decode(Row.self, from: line), let t = row.task ?? row.question {
                add(t, line)
            } else if let d = try? dec.decode(DoneLine.self, from: line), d.done {
                sawDone = true
                r.droppedCount = max(0, d.dropped ?? 0)
                r.doneWarn = d.warn.map { OutsideText.shown($0, max: 160) }
            } else if let h = try? dec.decode(Header.self, from: line) {
                r.schema = h.schema
                r.source = h.source.map { OutsideText.shown($0, max: 40) }
                r.sessionTitle = h.title.map { OutsideText.shown($0, max: 120) }
                headerPartial = h.partial ?? false
                r.headerWarn = h.warn.map { OutsideText.shown($0, max: 160) }
                r.answerable = h.answer == true
            } else if let t = try? dec.decode(Row.T.self, from: line), t.id != nil {
                add(t, line)   // #1974: a bare row (no "task" or "question" around it), known by its id
            } else { r.skippedLines += 1 }
        }
        r.partial = headerPartial || !sawDone
        return r
    }
}

/// #1815: one line of the Tasks list as drawn: a group's header ("Pending 30") or one of its tasks, under an id unique in
/// the whole list (XrayPanelModel.taskLines).
struct XrayTaskLine: Identifiable, Equatable {
    let id: String
    let header: String?
    let task: XrayTasks.Task?
}
