import Charts
import Foundation
import SwiftUI

/// #1484 (#1183 R3, spec 3.6): the "Usage history" card of the account pool pane: five charts over the usage record.
/// Reads only when the card first appears, when the range changes and on Refresh (no live polling). The read and the
/// five aggregations run off main; the model publishes the shaped result on main. Every outside string drawn (labels,
/// models, sessions, agents) goes through OutsideText.shown; a session id is never shown whole; no price anywhere.
@MainActor
final class CCPoolUsageStatsModel: ObservableObject {
    typealias Read = @Sendable (_ directory: URL, _ range: CCPoolUsageRange, _ now: Double) -> CCPoolUsageReadResult

    enum Span: String, CaseIterable, Identifiable, Sendable {
        case day = "24 h", week = "7 d", fortnight = "14 d"
        var id: String { rawValue }
        var range: CCPoolUsageRange {
            switch self {
            case .day: return .day
            case .week: return .week
            case .fortnight: return .fortnight
            }
        }
    }

    enum Grouping: String, CaseIterable, Identifiable, Sendable {
        case account = "Account", model = "Model", session = "Session"
        var id: String { rawValue }
    }

    /// The five token kinds, in the order of every `kinds` array below.
    nonisolated static let kinds = ["Input", "Cache write 5 min", "Cache write 1 h", "Cache read", "Output (incl. thinking)"]

    struct Line: Equatable, Sendable {
        var name: String
        var points: [CCPoolUsageStats.Point]
        /// Resets (utilisation) or moves to another account (cache hit rate).
        var markers: [Double]
    }

    struct Bar: Equatable, Sendable {
        var name: String
        var kinds: [Int]
        var total: Int
    }

    struct SessionRow: Equatable, Sendable {
        var name: String
        var kinds: [Int]
        var total: Int
        var requests: Int
        var accounts: String
        var agents: [SessionRow]
    }

    struct Finish: Equatable, Sendable {
        var model: String
        var day: String
        var median: Double
        var p90: Double
        var count: Int
    }

    struct Shown: Equatable, Sendable {
        var rows = 0
        var skipped = 0
        /// Percent.
        var utilization: [Line] = []
        var tokens: [Grouping: [Bar]] = [:]
        /// Percent.
        var cache: [Line] = []
        var top: [SessionRow] = []
        var finish: [Finish] = []

        static let titles = ["Utilisation per account", "Tokens by kind", "Cache hit rate per session", "Top sessions and subagents",
                             "Time to finish per model"]

        /// VoiceOver: each chart's label (its title) and a value that says what it shows.
        func charts(_ grouping: Grouping) -> [(title: String, summary: String)] {
            let pct = { (v: Double) in String(format: "%.0f%%", v) }
            let util = utilization.map { l in
                "\(l.name): latest \(pct(l.points.last?.value ?? 0)), peak \(pct(l.points.map(\.value).max() ?? 0)), "
                    + Self.count(l.markers.count, "reset")
            }
            let bars = (tokens[grouping] ?? []).map { "\($0.name): \(Self.count($0.total, "token"))" }
            let cacheText = cache.map { "\($0.name): latest \(pct($0.points.last?.value ?? 0)), \(Self.count($0.markers.count, "move"))" }
            let topText = top.first.map { "\(Self.count(top.count, "session")); most tokens: \($0.name), \(Self.count($0.total, "token"))" }
            let finishText = finish.map {
                "\($0.model) on \($0.day): median \(Self.seconds($0.median)), 90th percentile \(Self.seconds($0.p90)), "
                    + Self.count($0.count, "request")
            }
            let parts = [util, bars, cacheText, topText.map { [$0] } ?? [], finishText]
            return zip(Self.titles, parts).map { (title: $0, summary: $1.isEmpty ? "Nothing in this range." : $1.joined(separator: "; ")) }
        }

        static func count(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        static func seconds(_ ms: Double) -> String { String(format: "%.1f s", ms / 1000) }
    }

    let directory: URL
    let clock: @Sendable () -> Double
    /// Keychain id -> today's label, asked at each read (spec 3.3: the record holds the id, never the label).
    let labels: @MainActor () -> [String: String]
    let read: Read

    @Published private(set) var span: Span = .day
    @Published var grouping: Grouping = .account
    /// nil until the first read lands.
    @Published private(set) var shown: Shown?
    @Published private(set) var loading = false
    private var generation = 0

    nonisolated static let liveRead: Read = { CCPoolUsageReader.readNow(directory: $0, range: $1, now: $2) }

    init(directory: URL, clock: @escaping @Sendable () -> Double, labels: @escaping @MainActor () -> [String: String],
         read: @escaping Read = CCPoolUsageStatsModel.liveRead) {
        self.directory = directory
        self.clock = clock
        self.labels = labels
        self.read = read
    }

    /// Keychain id -> label from the pool's state.
    nonisolated static func labels(_ state: CCPoolState) -> [String: String] {
        Dictionary(state.accounts.map { ($0.value.id, $0.key) }, uniquingKeysWith: { min($0, $1) })
    }

    func appeared() {
        if shown == nil && !loading { reload() }
    }

    @discardableResult
    func select(_ span: Span) -> Task<Void, Never>? {
        guard span != self.span else { return nil }
        self.span = span
        return reload()
    }

    /// A later read wins: an earlier one that lands after it is dropped.
    @discardableResult
    func reload() -> Task<Void, Never> {
        generation += 1
        let g = generation, dir = directory, range = span.range, now = clock(), names = labels(), read = read
        loading = true
        return Task { [weak self] in
            // Spec 3.5: the read and the aggregations off main; only the shaped result is published here.
            let s = await Task.detached { CCPoolUsageStatsModel.shape(read(dir, range, now), labels: names) }.value
            guard let self, g == self.generation else { return }
            self.shown = s
            self.loading = false
        }
    }

    // MARK: shaping (pure, off main)

    nonisolated static func shape(_ r: CCPoolUsageReadResult, labels: [String: String]) -> Shown {
        let rows = r.rows
        let accts = names(Set(rows.map(\.acct))) { id in labels[id].map { OutsideText.shown($0, max: 40) } ?? "removed account" }
        let sessions = names(Set(rows.compactMap(\.sess)), shortSession)
        let models = names(Set(rows.map(\.model))) { OutsideText.shown($0, max: 64) }
        func kinds(_ t: CCPoolUsageTotals) -> [Int] { [t.input, t.cacheWrite5m, t.cacheWrite1h, t.cacheRead, t.output] }
        func percent(_ p: [CCPoolUsageStats.Point]) -> [CCPoolUsageStats.Point] { p.map { .init(t: $0.t, value: $0.value * 100) } }

        var s = Shown(rows: rows.count, skipped: r.skippedTotal)
        s.utilization = CCPoolUsageStats.utilization(rows).map {
            Line(name: "\(accts[$0.acct] ?? "") \u{00B7} \($0.window == "five_hour" ? "5 h" : "7 d")", points: percent($0.points),
                 markers: $0.resets.map(\.t))
        }
        for (g, group, map) in [(Grouping.account, CCPoolUsageGroup.account, accts), (Grouping.model, CCPoolUsageGroup.model, models),
                                    (Grouping.session, CCPoolUsageGroup.session, sessions)] {
            s.tokens[g] = CCPoolUsageStats.tokens(rows, by: group).map { Bar(name: map[$0.key] ?? "", kinds: kinds($0.totals), total: $0.totals.total) }
        }
        s.cache = CCPoolUsageStats.cacheHitRate(rows).map { c in
            Line(name: sessions[c.sess] ?? "", points: c.points.map { .init(t: $0.t, value: $0.rate * 100) },
                 markers: c.points.filter(\.moved).map(\.t))
        }
        s.top = CCPoolUsageStats.topSessions(rows).map { t in
            SessionRow(name: sessions[t.sess] ?? "", kinds: kinds(t.totals), total: t.totals.total, requests: t.totals.requests,
                       accounts: t.accounts.map { accts[$0] ?? "" }.joined(separator: ", "),
                       agents: t.agents.map { a in
                           SessionRow(name: a.agent.isEmpty ? "main" : "subagent " + OutsideText.shown(a.agent, max: 16), kinds: kinds(a.totals),
                                      total: a.totals.total, requests: a.totals.requests, accounts: "", agents: [])
                       })
        }
        s.finish = CCPoolUsageStats.finishTimes(rows).map {
            Finish(model: models[$0.model] ?? "", day: $0.day, median: $0.median, p90: $0.p90, count: $0.count)
        }
        return s
    }

    /// Spec 3.6: never the whole id, anywhere: at most its first 8 characters and always fewer than it has, then an ellipsis.
    nonisolated static func shortSession(_ id: String) -> String {
        let s = OutsideText.shown(id, max: Int.max)
        return String(s.prefix(min(8, max(0, s.count - 1)))) + "\u{2026}"
    }

    /// One display name per key, never two alike (two removed accounts, two sessions cut to the same start): a repeat
    /// gets " (2)", " (3)", in key order.
    nonisolated static func names(_ keys: Set<String>, _ shown: (String) -> String) -> [String: String] {
        var out: [String: String] = [:], used: Set<String> = []
        for k in keys.sorted() {
            let base = shown(k)
            var name = base, n = 1
            while used.contains(name) { n += 1; name = "\(base) (\(n))" }
            used.insert(name)
            out[k] = name
        }
        return out
    }
}

struct CCPoolUsageStatsSection: View {
    @ObservedObject var model: CCPoolUsageStatsModel

    static let footer = "Read from this Mac's usage record when the pane opens, when the range changes and on Refresh. "
        + "Session ids are cut to their first characters. Quota checks count for utilisation only."

    var body: some View {
        content.onAppear { model.appeared() }
    }

    /// The card without its appear hook (the tests read its strings from here).
    var content: some View {
        NeonSection("Usage history", footer: Self.footer) {
            VStack(alignment: .leading, spacing: sz(12)) {
                fitting {
                    Picker("Range", selection: Binding(get: { model.span }, set: { model.select($0) })) {
                        ForEach(CCPoolUsageStatsModel.Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel("Range")
                    Button(model.loading ? "Reading\u{2026}" : "Refresh") { model.reload() }
                        .buttonStyle(.neon).fixedSize().disabled(model.loading)
                }
                if let s = model.shown {
                    shownView(s)
                } else {
                    caption("Not read yet.")
                }
            }
        }
    }

    @ViewBuilder
    private func shownView(_ s: CCPoolUsageStatsModel.Shown) -> some View {
        if s.skipped > 0 {
            caption("\(CCPoolUsageStatsModel.Shown.count(s.skipped, "unreadable row")) skipped.", color: Neon.magenta)
        }
        if s.rows == 0 {
            caption("No usage recorded in this range.")
        } else {
            let charts = s.charts(model.grouping)
            ForEach(Array(charts.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: sz(6)) {
                    Text(c.title).font(Neon.font(.caption)).foregroundStyle(Neon.textPrimary)
                    chart(i, s)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(c.title)
                        .accessibilityValue(c.summary)
                }
            }
        }
    }

    @ViewBuilder
    private func chart(_ i: Int, _ s: CCPoolUsageStatsModel.Shown) -> some View {
        switch i {
        case 0: lines(s.utilization, y: "Percent").frame(height: sz(160))
        case 1:
            VStack(alignment: .leading, spacing: sz(6)) {
                Picker("Group by", selection: $model.grouping) {
                    ForEach(CCPoolUsageStatsModel.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                bars(s.tokens[model.grouping] ?? []).frame(height: sz(160))
            }
        case 2: lines(s.cache, y: "Percent").chartYScale(domain: 0...100).frame(height: sz(160))
        case 3: table(s.top)
        default: finish(s.finish).frame(height: sz(160))
        }
    }

    private func lines(_ lines: [CCPoolUsageStatsModel.Line], y: String) -> some View {
        Chart {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                ForEach(Array(l.points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value(y, p.value), series: .value("Line", l.name))
                        .foregroundStyle(by: .value("Line", l.name))
                }
                ForEach(Array(l.markers.enumerated()), id: \.offset) { _, t in
                    RuleMark(x: .value("Marker", Date(timeIntervalSince1970: t)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Neon.textSecondary)
                }
            }
        }
    }

    private func bars(_ bars: [CCPoolUsageStatsModel.Bar]) -> some View {
        Chart {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                ForEach(Array(zip(CCPoolUsageStatsModel.kinds, b.kinds).enumerated()), id: \.offset) { _, k in
                    BarMark(x: .value("Group", b.name), y: .value("Tokens", k.1))
                        .foregroundStyle(by: .value("Kind", k.0))
                }
            }
        }
    }

    private func finish(_ rows: [CCPoolUsageStatsModel.Finish]) -> some View {
        Chart {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, f in
                LineMark(x: .value("Day", f.day), y: .value("Seconds", f.median / 1000), series: .value("Series", "\(f.model) median"))
                    .foregroundStyle(by: .value("Series", "\(f.model) median")).symbol(.circle)
                LineMark(x: .value("Day", f.day), y: .value("Seconds", f.p90 / 1000), series: .value("Series", "\(f.model) 90th"))
                    .foregroundStyle(by: .value("Series", "\(f.model) 90th")).symbol(.circle)
            }
        }
    }

    private func table(_ rows: [CCPoolUsageStatsModel.SessionRow]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: sz(10), verticalSpacing: sz(4)) {
                GridRow {
                    ForEach(["Session"] + CCPoolUsageStatsModel.kinds + ["Requests", "Accounts"], id: \.self) { cell($0, color: Neon.textSecondary) }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    row(r)
                    ForEach(Array(r.agents.enumerated()), id: \.offset) { _, a in row(a, indent: true) }
                }
            }
        }
    }

    private func row(_ r: CCPoolUsageStatsModel.SessionRow, indent: Bool = false) -> some View {
        GridRow {
            cell(r.name).padding(.leading, indent ? sz(12) : 0)
            ForEach(Array(r.kinds.enumerated()), id: \.offset) { _, n in cell("\(n)") }
            cell("\(r.requests)")
            cell(r.accounts)
        }
    }

    private func cell(_ text: String, color: Color = Neon.textPrimary) -> some View {
        Text(text).font(Neon.font(.caption)).foregroundStyle(color).lineLimit(1)
    }

    private func caption(_ text: String, color: Color = Neon.textSecondary) -> some View {
        Text(text).font(Neon.font(.caption)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One row when it fits, stacked when it does not (as CCPoolPane.fitting).
    private func fitting<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: sz(8)) { c }
            VStack(alignment: .leading, spacing: sz(6)) { c }
        }
    }
}
