import SwiftUI

// #2014 (dch #685/#686, 1.188.0): X-ray's Schedules tab: a session's crons, its /loop wake-up and Codex heartbeats, from
// the follow's schedules block (`dch --xray <n> --follow ... --schedules --json`; no read of its own, no timer: the
// countdowns move with the panel's ticker). dch README "--schedules": a header ("block":"schedules", live, partial,
// warn), {"schedule":{...}} rows in dch's order (pending crons soonest first, the wake-up, the rest), a done line.

/// One session's schedules as dch prints them. Every string is outside data.
struct XraySchedules: Equatable {
    enum Kind: String, Equatable { case cron, wakeup, heartbeat }

    struct Schedule: Equatable {
        var id: String
        var kind: Kind
        /// dch's word (pending, fired, deleted, expired, ended); a pending row of a header with live:false reads "ended".
        var status: String
        var recurring: Bool
        var durable: Bool
        var cron: String?
        var human: String?
        var prompt: String?
        var next: Date?
        var expires: Date?
        var fires: Int

        var pending: Bool { status == "pending" }
    }

    var schema: Int?
    /// "claude", "codex", or "none" (a shell: no tab).
    var source: String?
    var live: Bool
    var partial: Bool
    var warn: String?
    var schedules: [Schedule]

    /// The tab's count: the pending rows.
    var pendingCount: Int { schedules.filter(\.pending).count }
    /// The /loop marker: a pending wake-up.
    var loopActive: Bool { schedules.contains { $0.kind == .wakeup && $0.pending } }

    // MARK: wire

    private struct Header: Decodable {
        let schema: Int
        let block: String?
        let source: String?
        let live: Bool?
        let partial: Bool?
        let warn: String?
    }

    private struct Row: Decodable {
        struct S: Decodable {
            let id: String?
            let kind: String?
            let status: String?
            let recurring: Bool?
            let durable: Bool?
            let cron: String?
            let human: String?
            let prompt: String?
            let next: String?
            let expires: String?
            let fires: Int?
        }
        let schedule: S
    }

    private struct DoneLine: Decodable { let done: Bool }

    /// The parse: the block's lines in, never throws; a bad line or a row of an unknown kind is skipped. dch caps the
    /// block at 5000 rows; the follow's maxBlockRows bounds what reaches here.
    static func parse(_ lines: [Data]) -> XraySchedules {
        var r = XraySchedules(schema: nil, source: nil, live: true, partial: true, warn: nil, schedules: [])
        var sawDone = false, headerPartial = false
        let dec = JSONDecoder()
        for line in lines where !line.isEmpty && line.count <= XrayTasks.maxLine {
            if let row = try? dec.decode(Row.self, from: line) {
                let s = row.schedule
                guard let id = s.id, let kind = Kind(rawValue: s.kind ?? "") else { continue }
                r.schedules.append(Schedule(
                    id: OutsideText.shown(id, max: 64), kind: kind, status: OutsideText.shown(s.status ?? "", max: 20),
                    recurring: s.recurring ?? false, durable: s.durable ?? false,
                    cron: s.cron.map { OutsideText.shown($0, max: 64) }, human: s.human.map { OutsideText.shown($0, max: 64) },
                    prompt: s.prompt.map { OutsideText.shown($0, max: 120) },
                    next: XrayTasks.date(s.next), expires: XrayTasks.date(s.expires), fires: max(0, s.fires ?? 0)))
            } else if let d = try? dec.decode(DoneLine.self, from: line), d.done {
                sawDone = true
            } else if let h = try? dec.decode(Header.self, from: line) {
                r.schema = h.schema
                r.source = h.source.map { OutsideText.shown($0, max: 40) }
                r.live = h.live ?? true
                headerPartial = h.partial ?? false
                r.warn = h.warn.map { OutsideText.shown($0, max: 160) }
            }
        }
        r.partial = headerPartial || !sawDone
        // dch README: the agent gone (live:false), its pending crons and wake-up read "ended"; held here too in case a
        // row's own delta came before the block that says so
        if !r.live { for i in r.schedules.indices where r.schedules[i].pending { r.schedules[i].status = "ended" } }
        return r
    }
}

/// #2014: one Schedules row as drawn, at `now`.
struct XrayScheduleRow: Equatable {
    let id: String
    let mark: String
    let kind: String
    let what: String
    let status: String
    let flags: String
    let prompt: String
    let countdown: String?

    init(_ s: XraySchedules.Schedule, now: Date) {
        id = s.id
        (mark, kind) = switch s.kind {
        case .cron: ("clock.arrow.circlepath", "cron")
        case .wakeup: ("alarm", "wake-up")
        case .heartbeat: ("heart", "heartbeat")
        }
        what = s.human ?? s.cron ?? ""
        // dch README: "a client ... turns a row expired at `expires` itself"
        status = s.pending && s.recurring && s.expires.map { $0 <= now } == true ? "expired" : s.status
        flags = [s.recurring ? "recurring" : nil, s.durable ? "durable" : nil].compactMap { $0 }.joined(separator: ", ")
        prompt = s.prompt ?? ""
        countdown = status == "pending" ? (s.next ?? s.expires).map { Self.countdown($0, now: now) } : nil
    }

    /// "in 1m 30s" under an hour, "in 2h 5m", "in 3d 4h"; "due" once it passed (dch sends nothing as time goes).
    static func countdown(_ at: Date, now: Date) -> String {
        let d = at.timeIntervalSince(now)
        guard d > 0 else { return "due" }
        let s = Int(min(d, 1e9).rounded(.up))   // bounded before Int(: a far-future date never traps
        if s < 60 { return "in \(s)s" }
        if s < 3600 { return "in \(s / 60)m" + (s % 60 > 0 ? " \(s % 60)s" : "") }
        if s < 86400 { return "in \(s / 3600)h \(s % 3600 / 60)m" }
        return "in \(s / 86400)d \(s % 86400 / 3600)h"
    }

    var spoken: String {
        [kind, what, status, flags, prompt, countdown ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension XrayPanelModel {
    /// #2014: a block shows as a tab for an agent's session (schema 1, a Claude or Codex source; a shell has none).
    static func schedulesTab(_ s: XraySchedules) -> XraySchedules? { s.schema == 1 && s.source != "none" ? s : nil }

    /// #2014: the countdowns' clock: the second while a pending row is due within the hour, else the minute.
    func scheduleClock() -> Int {
        let t = now().timeIntervalSince1970
        let soon = schedules?.schedules.contains { s in
            s.pending && (s.next ?? s.expires).map { $0.timeIntervalSince1970 - t < 3600 } == true
        } == true
        return Int(max(-1e12, min(soon ? t : t / 60, 1e12)).rounded(.down)) * (soon ? 1 : 60)
    }

    /// #2014: the ticker's (each second) while Schedules shows: one redraw when the countdowns' clock moved, none else.
    func schedulesTick() {
        let c = scheduleClock()
        if c != schedulesClock { schedulesClock = c; schedulesRedraws &+= 1; objectWillChange.send() }
    }
}

extension XrayPanelView {
    /// #2014: the Schedules list, in dch's order; a delta replaces its row in place.
    var schedulesTab: some View {
        let now = panel.now(), rows = (panel.schedules?.schedules ?? []).map { XrayScheduleRow($0, now: now) }
        return VStack(alignment: .leading, spacing: sz(4)) {
            if let n = panel.schedulesNote { faint(n) }
            else if rows.isEmpty { faint("No schedules in this session") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(zip(XrayScrollAnchor.unique(rows.map { "s:" + $0.id }), rows).map { ($0, $1) }, id: \.0) { id, r in
                        XrayScheduleRowView(row: r).modifier(XrayScrollRow(panel: panel, id: id))
                    }
                }
                .scrollTargetLayout()
            }
            if let w = panel.schedules?.warn { faint(w) }
        }
        .padding(sz(10))
    }
}

struct XrayScheduleRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: XrayScheduleRow

    var body: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: row.mark).foregroundStyle(Neon.textSecondary)
            Text(verbatim: row.what).foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize()
            Text(verbatim: row.prompt).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer(minLength: sz(4))
            if !row.flags.isEmpty { Text(verbatim: row.flags).foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize() }
            Text(verbatim: row.status).foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize()
            if let c = row.countdown { Text(verbatim: c).monospacedDigit().foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize() }
        }
        .font(Neon.font(XrayText.row))
        .frame(height: sz(XrayText.rowHeight))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}
