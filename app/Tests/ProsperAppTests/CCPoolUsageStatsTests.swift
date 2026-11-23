import AppKit
import Charts
import SwiftUI
import XCTest
@testable import ProsperApp

// #1484 (#1183 R3): the Usage history card. Literal rows written to a record folder under the row's tempDir() (fake
// accounts "id-a" = Example Org A, "id-b" = Example Org B, one removed id; sessions s-0001...), read through the real
// reader, literal expected chart models. Hosted offscreen only: no window, nothing clicked, no event posted.

private let stNow = 1_800_000_000.0          // 2027-01-15 08:00:00 UTC
private let stDay = 86_400.0
private let stLabels = ["id-a": "Example Org A", "id-b": "Example Org B"]

/// One row as JSON text, in the writer's shape; tokens are (in, out, cr, cw5, cw1); lim is five_hour (u, r).
private func stLine(_ t: Double, acct: String = "id-a", model: String = "claude-opus-5", sess: String? = "s-0001", agent: String = "",
                    st: Int = 200, ms: Int = 1000, done: Bool = true, qc: Bool = false, tok: [Int]? = nil, five: (Double, Double)? = nil) -> String {
    var o: [String: Any] = ["v": 1, "t": t, "acct": acct, "model": model, "path": "messages", "st": st, "ms": ms, "done": done, "qc": qc,
                            "att": 1, "thr": 0, "mv": false, "routed": "pin"]
    if let sess { o["sess"] = sess; o["agent"] = agent }
    if let tok, tok.count == 5 { for (k, v) in zip(["in", "out", "cr", "cw5", "cw1"], tok) { o[k] = v } }
    if let five { o["lim"] = ["five_hour": ["u": five.0, "r": five.1, "s": "a"] as [String: Any]] }
    let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    return String(decoding: data ?? Data(), as: UTF8.self)
}

private final class StReads: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(range: CCPoolUsageRange, onMain: Bool)] = []
    var calls: [(range: CCPoolUsageRange, onMain: Bool)] { lock.withLock { _calls } }
    func add(_ r: CCPoolUsageRange, _ main: Bool) { lock.withLock { _calls.append((r, main)) } }
}

@MainActor
final class CCPoolUsageStatsTests: XCTestCase {
    private typealias M = CCPoolUsageStatsModel
    private var t1: Double { stNow - 13 * stDay }
    private var t3: Double { stNow - 7 * stDay }

    /// A record folder under tempDir() holding `files` (name -> lines), and a model on it whose reads are recorded.
    private func rig(_ files: [String: [String]], labels: [String: String] = stLabels) throws -> (M, StReads) {
        let dir = tempDir().appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, lines) in files { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(n)) }
        let reads = StReads()
        let model = M(directory: dir, clock: { stNow }, labels: { labels }, read: { d, r, now in
            reads.add(r, Thread.isMainThread)
            return CCPoolUsageReader.readNow(directory: d, range: r, now: now)
        })
        return (model, reads)
    }

    /// The 14-day fixture: two accounts, a removed one, two sessions, a subagent, a move, a quota check, a failed reply,
    /// a reset, and one line that does not decode.
    private func fortnight() throws -> (M, StReads) {
        try rig([
            "usage-2027-01-02.jsonl": [stLine(t1, tok: [100, 50, 0, 900, 0], five: (0.25, t1 + 3600)),
                                       stLine(t1 + 60, agent: "a-1", ms: 3000, tok: [100, 50, 300, 0, 0], five: (0.125, t1 + 3600))],
            "usage-2027-01-08.jsonl": [stLine(t3, acct: "id-b", ms: 2000, tok: [100, 100, 0, 1900, 0], five: (0.5, t3 + 3600)),
                                       stLine(t3 + 60, model: "claude-sonnet-5", sess: "s-0002", ms: 100, qc: true, five: (0.75, t3 + 3660))],
            "usage-2027-01-15.jsonl": [stLine(stNow - 3600, acct: "id-removed", model: "claude-sonnet-5", sess: nil, ms: 2000, tok: [10, 20, 30, 40, 0]),
                                       "{not json", stLine(stNow - 60, sess: "s-0002", st: 529, ms: 500, done: false)],
        ])
    }

    /// Every string the card's view values hold (the walk of CCPoolPaneTests: closures of sections, rows and ForEach
    /// called; class instances not entered except SwiftUI's text storage).
    private func walked(_ m: M) -> [String] {
        var out: [String] = []
        func walk(_ v: Any, _ depth: Int) {
            guard depth < 120 else { return }
            if let s = v as? String { out.append(s); return }
            let mirror = Mirror(reflecting: v)
            if mirror.displayStyle == .class, !"\(type(of: v))".contains("TextStorage") { return }
            if let inner = v as? CCPoolViewInner { inner.ccpoolInner.forEach { walk($0, depth + 1) } }
            for c in mirror.children { walk(c.value, depth + 1) }
        }
        walk(CCPoolUsageStatsSection(model: m).content, 0)
        return out
    }

    /// The walk plus the published chart models and every chart's VoiceOver label and value.
    private func rendered(_ m: M) -> [String] {
        var dumped = ""
        dump(m.shown, to: &dumped)
        let charts = M.Grouping.allCases.flatMap { g in (m.shown?.charts(g) ?? []).flatMap { [$0.title, $0.summary] } }
        return walked(m) + [dumped] + charts
    }

    private func line(_ name: String, _ pts: [(Double, Double)], _ markers: [Double] = []) -> M.Line {
        M.Line(name: name, points: pts.map { .init(t: $0.0, value: $0.1) }, markers: markers)
    }

    // MARK: fixtures

    func testEmptyRecordShowsTheEmptyStateAndNoCharts() async throws {
        let (m, _) = try rig([:])
        XCTAssertTrue(walked(m).contains("Not read yet."))
        await m.reload().value
        var empty = M.Shown()
        empty.tokens = [.account: [], .model: [], .session: []]
        XCTAssertEqual(m.shown, empty)
        XCTAssertTrue(walked(m).contains("No usage recorded in this range."))
        XCTAssertFalse(walked(m).contains(M.Shown.titles[0]), "no chart without rows")
        XCTAssertEqual(m.shown?.charts(.account).map(\.summary), Array(repeating: "Nothing in this range.", count: 5))
    }

    func testOneRowRendersEveryChartModel() async throws {
        let t = stNow - 600
        let (m, _) = try rig(["usage-2027-01-15.jsonl": [stLine(t, ms: 1500, tok: [500, 250, 3000, 400, 100], five: (0.5, stNow + 3000))]])
        await m.reload().value
        let s = try XCTUnwrap(m.shown)
        XCTAssertEqual(s.rows, 1)
        XCTAssertEqual(s.skipped, 0)
        XCTAssertEqual(s.utilization, [line("Example Org A \u{00B7} 5 h", [(t, 50)])])
        let kinds = [500, 400, 100, 3000, 250]
        XCTAssertEqual(s.tokens, [.account: [M.Bar(name: "Example Org A", kinds: kinds, total: 4250)],
                                  .model: [M.Bar(name: "claude-opus-5", kinds: kinds, total: 4250)],
                                  .session: [M.Bar(name: "s-000\u{2026}", kinds: kinds, total: 4250)]])
        XCTAssertEqual(s.cache, [line("s-000\u{2026}", [(t, 75)])])
        let main = M.SessionRow(name: "main", kinds: kinds, total: 4250, requests: 1, accounts: "", agents: [])
        XCTAssertEqual(s.top, [M.SessionRow(name: "s-000\u{2026}", kinds: kinds, total: 4250, requests: 1, accounts: "Example Org A", agents: [main])])
        XCTAssertEqual(s.finish, [M.Finish(model: "claude-opus-5", day: "2027-01-15", median: 1500, p90: 1500, count: 1)])
        XCTAssertEqual(s.charts(.session).map(\.summary), [
            "Example Org A \u{00B7} 5 h: latest 50%, peak 50%, 0 resets",
            "s-000\u{2026}: 4250 tokens",
            "s-000\u{2026}: latest 75%, 0 moves",
            "1 session; most tokens: s-000\u{2026}, 4250 tokens",
            "claude-opus-5 on 2027-01-15: median 1.5 s, 90th percentile 1.5 s, 1 request",
        ])
    }

    func testFourteenDayFixtureRendersEveryChartModel() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let s = try XCTUnwrap(m.shown)
        XCTAssertEqual(s.rows, 6)
        XCTAssertEqual(s.skipped, 1)
        // Running max inside one reset (25 stays 25 after 12.5), a new reset starts over with a marker; the quota check counts.
        XCTAssertEqual(s.utilization, [line("Example Org A \u{00B7} 5 h", [(t1, 25), (t1 + 60, 25), (t3 + 60, 75)], [t3 + 60]),
                                       line("Example Org B \u{00B7} 5 h", [(t3, 50)])])
        XCTAssertEqual(s.tokens[.account], [M.Bar(name: "Example Org A", kinds: [200, 900, 0, 300, 100], total: 1500),
                                            M.Bar(name: "Example Org B", kinds: [100, 1900, 0, 0, 100], total: 2100),
                                            M.Bar(name: "removed account", kinds: [10, 40, 0, 30, 20], total: 100)])
        XCTAssertEqual(s.tokens[.model], [M.Bar(name: "claude-opus-5", kinds: [300, 2800, 0, 300, 200], total: 3600),
                                          M.Bar(name: "claude-sonnet-5", kinds: [10, 40, 0, 30, 20], total: 100)])
        XCTAssertEqual(s.tokens[.session], [M.Bar(name: "s-000\u{2026}", kinds: [300, 2800, 0, 300, 200], total: 3600)])
        // The move to Example Org B is a marker, and its cache write shows as the dip to 0.
        XCTAssertEqual(s.cache, [line("s-000\u{2026}", [(t1, 0), (t1 + 60, 75), (t3, 0)], [t3])])
        XCTAssertEqual(s.top, [M.SessionRow(
            name: "s-000\u{2026}", kinds: [300, 2800, 0, 300, 200], total: 3600, requests: 3, accounts: "Example Org A, Example Org B", agents: [
                M.SessionRow(name: "main", kinds: [200, 2800, 0, 0, 150], total: 3150, requests: 2, accounts: "", agents: []),
                M.SessionRow(name: "subagent a-1", kinds: [100, 0, 0, 300, 50], total: 450, requests: 1, accounts: "", agents: []),
            ])])
        XCTAssertEqual(s.finish, [M.Finish(model: "claude-opus-5", day: "2027-01-02", median: 2000, p90: 3000, count: 2),
                                  M.Finish(model: "claude-opus-5", day: "2027-01-08", median: 2000, p90: 2000, count: 1),
                                  M.Finish(model: "claude-sonnet-5", day: "2027-01-15", median: 2000, p90: 2000, count: 1)])
        XCTAssertEqual(s.charts(.account).map(\.summary), [
            "Example Org A \u{00B7} 5 h: latest 75%, peak 75%, 1 reset; Example Org B \u{00B7} 5 h: latest 50%, peak 50%, 0 resets",
            "Example Org A: 1500 tokens; Example Org B: 2100 tokens; removed account: 100 tokens",
            "s-000\u{2026}: latest 0%, 1 move",
            "1 session; most tokens: s-000\u{2026}, 3600 tokens",
            "claude-opus-5 on 2027-01-02: median 2.0 s, 90th percentile 3.0 s, 2 requests; "
                + "claude-opus-5 on 2027-01-08: median 2.0 s, 90th percentile 2.0 s, 1 request; "
                + "claude-sonnet-5 on 2027-01-15: median 2.0 s, 90th percentile 2.0 s, 1 request",
        ])
        let r = walked(m)
        XCTAssertTrue(r.contains("1 unreadable row skipped."), "the skipped count is shown")
        // VoiceOver: each chart's title is drawn, and its label/value pair is the model's.
        XCTAssertEqual(s.charts(.model).map(\.title), ["Utilisation per account", "Tokens by kind", "Cache hit rate per session",
                                                       "Top sessions and subagents", "Time to finish per model"])
        for title in M.Shown.titles { XCTAssertTrue(r.contains(title), title) }
    }

    func testRangePickerReReadsOffMain() async throws {
        let (m, reads) = try fortnight()
        await m.reload().value
        XCTAssertEqual(m.shown?.rows, 2, "24 h: the two rows of the last day")
        await m.select(.week)?.value
        XCTAssertEqual(m.shown?.rows, 4, "7 d starts at the first row of 2027-01-08")
        XCTAssertTrue(m.select(.week) == nil, "the same range does not read again")
        await m.select(.fortnight)?.value
        XCTAssertEqual(m.shown?.rows, 6)
        XCTAssertEqual(reads.calls.map(\.range), [.day, .week, .fortnight])
        XCTAssertEqual(reads.calls.map(\.onMain), [false, false, false], "every read runs off main")
    }

    // MARK: what is never shown

    func testNoSessionIdIsShownWholeAnywhere() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let r = rendered(m)
        XCTAssertTrue(r.contains { $0.contains("s-000\u{2026}") }, "the walk saw the sessions")
        for id in ["s-0001", "s-0002"] { XCTAssertFalse(r.contains { $0.contains(id) }, id) }
        XCTAssertEqual(M.shortSession("0f3c2a9e-1111-4222-8333-944445555666"), "0f3c2a9e\u{2026}")
        XCTAssertEqual(M.shortSession("s-0001"), "s-000\u{2026}")
        XCTAssertEqual(M.shortSession("s"), "\u{2026}")
        XCTAssertEqual(M.names(["s-0001", "s-0002", "s-0003"], M.shortSession),
                       ["s-0001": "s-000\u{2026}", "s-0002": "s-000\u{2026} (2)", "s-0003": "s-000\u{2026} (3)"])
    }

    func testNoPriceOrCurrencyAnywhere() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let text = rendered(m).joined(separator: "\n") + CCPoolUsageStatsSection.footer
        for needle in ["$", "\u{20AC}", "\u{00A3}", "\u{00A5}", "USD", "price", "Price", "cost", "Cost", "dollar"] {
            XCTAssertFalse(text.contains(needle), needle)
        }
    }

    // QA r1448 i1: account labels, models, sessions and agents are outside strings: drawn only through OutsideText.shown.
    func testOutsideStringsAreDrawnCleaned() async throws {
        let rlo = "\u{202E}", bell = "\u{0007}", rlm = "\u{200F}", acute = "\u{0301}"
        let (m, _) = try rig(["usage-2027-01-15.jsonl": [
            stLine(stNow - 60, model: "claude-" + rlo + "x" + bell + "e" + String(repeating: acute, count: 6), sess: "s-" + rlm + "0009-extra",
                   agent: rlo + "sub-1", tok: [100, 0, 100, 0, 0], five: (0.5, stNow + 600)),
        ]], labels: ["id-a": "Example Org A" + rlo + bell])
        await m.reload().value
        let s = try XCTUnwrap(m.shown)
        let model = "claude-xe" + String(repeating: acute, count: 3)
        XCTAssertEqual(s.finish.map(\.model), [model])
        XCTAssertEqual(s.tokens[.model]?.map(\.name), [model])
        XCTAssertEqual(s.top.map(\.name), ["s-0009-e\u{2026}"])
        XCTAssertEqual(s.top.first?.agents.map(\.name), ["subagent sub-1"])
        XCTAssertEqual(s.top.first?.accounts, "Example Org A")
        XCTAssertEqual(s.utilization.map(\.name), ["Example Org A \u{00B7} 5 h"])
        for text in rendered(m) {
            XCTAssertFalse(text.unicodeScalars.contains { OutsideText.isUnseen($0) && $0 != "\n" }, text.debugDescription)
            XCTAssertFalse(text.contains(String(repeating: acute, count: 4)), "marks capped")
        }
    }

    // MARK: bounded marks (QA r1458 R1484a-m1)

    /// 200,000 generated rows (no fixture file): 5 accounts, 400 sessions, 2 models, 14 days, both quota windows with
    /// resets, a session that moves account every 50 rows.
    private func busyRows() -> [CCPoolUsageEntry] {
        let n = 200_000, start = stNow - 14 * stDay
        return (0..<n).map { i in
            let t = start + Double(i) * (14 * stDay / Double(n))
            let r5 = (t / 18_000).rounded(.down) * 18_000 + 18_000, r7 = (t / 604_800).rounded(.down) * 604_800 + 604_800
            return CCPoolUsageEntry(
                t: t, acct: "id-\(i / 50 % 40)", model: "claude-model-\(i % 30)", sess: "s-\(i % 400)", agent: "",
                path: "messages", st: 200, ms: 500 + i % 3000, done: true, qc: false, att: 1, thr: 0, mv: false, routed: "pin",
                tokens: .init(input: 10 + i % 7, output: 5, cacheRead: i % 1000, cacheWrite5m: 1, cacheWrite1h: 0),
                lim: ["five_hour": .init(u: 1 - (r5 - t) / 18_000, r: r5, s: "a"), "seven_day": .init(u: 1 - (r7 - t) / 604_800, r: r7, s: "a")])
        }
    }

    func testBusyFortnightKeepsEveryChartUnderTheMarkAndSeriesBounds() {
        let rows = busyRows()
        XCTAssertEqual(rows.count, 200_000)
        let t0 = Date()
        let s = M.shape(CCPoolUsageReadResult(rows: rows), labels: stLabels)
        print("SHAPE200K seconds=\(Date().timeIntervalSince(t0))")
        // Item 3 fact: what the reader's per-series aggregations alone cost on the same rows (no assert on time).
        for (name, run) in [("utilization", { _ = CCPoolUsageStats.utilization(rows) }), ("tokens", { _ = CCPoolUsageStats.tokens(rows, by: .session) }),
                            ("cacheHitRate", { _ = CCPoolUsageStats.cacheHitRate(rows) }), ("topSessions", { _ = CCPoolUsageStats.topSessions(rows) }),
                            ("finishTimes", { _ = CCPoolUsageStats.finishTimes(rows) })] as [(String, () -> Void)] {
            let t = Date()
            run()
            print("SHAPE200K \(name) seconds=\(Date().timeIntervalSince(t))")
        }
        XCTAssertEqual(s.rows, 200_000)
        // Marks and series per chart, counted from shape()'s output.
        let lineMarks = { (l: [M.Line]) in l.reduce(0) { $0 + $1.points.count + $1.markers.count } }
        XCTAssertLessThanOrEqual(lineMarks(s.utilization), 2000)
        XCTAssertLessThanOrEqual(s.utilization.count, 25)
        XCTAssertEqual(s.utilization.count, 25, "24 busiest lines of the 80 (40 accounts, two windows) plus other")
        XCTAssertEqual(s.utilization.last?.name, "other (56)")
        XCTAssertLessThanOrEqual(lineMarks(s.cache), 2000)
        XCTAssertEqual(s.cache.count, 10, "hit rate keeps the busiest 10 sessions")
        XCTAssertEqual(s.moreSessions, 390)
        XCTAssertTrue(s.charts(.account)[2].summary.hasSuffix("; and 390 more"), "the summary says how many are left out")
        for g in M.Grouping.allCases {
            let bars = s.tokens[g] ?? []
            XCTAssertLessThanOrEqual(bars.count * M.kinds.count, 2000)
            XCTAssertLessThanOrEqual(M.kinds.count, 25)
            XCTAssertEqual(bars.reduce(0) { $0 + $1.total }, s.tokens[.account]?.reduce(0) { $0 + $1.total }, "other keeps the rest, nothing is lost")
        }
        XCTAssertEqual(s.tokens[.session]?.count, 21, "top 20 plus other")
        XCTAssertEqual(s.tokens[.session]?.last?.name, "other (380)")
        XCTAssertLessThanOrEqual(2 * s.finish.count, 2000)
        let finishModels = Set(s.finish.map(\.model))
        XCTAssertLessThanOrEqual(2 * finishModels.count, 25, "two series per model")
        XCTAssertEqual(finishModels.count, 12, "11 of the 30 models plus other")
        XCTAssertTrue(finishModels.contains("other (19)"))
        XCTAssertEqual(s.finish.reduce(0) { $0 + $1.count }, 200_000, "other keeps every finished request")
        for l in s.utilization + s.cache {
            XCTAssertLessThanOrEqual(l.points.count, M.pointsMax)
            XCTAssertLessThanOrEqual(l.markers.count, l.points.count, "a marker per bucket at most")
        }
        XCTAssertGreaterThan(s.utilization.reduce(0) { $0 + $1.markers.count }, 0, "resets still marked")
    }

    func testThinKeepsPeaksMeansAndOneMarkerPerBucket() {
        let p = (0..<100).map { CCPoolUsageStats.Point(t: Double($0), value: Double($0 % 10)) }
        let (peak, m) = M.thin(p, [1, 2, 3, 98, 99], cap: 10, mean: false)
        XCTAssertEqual(peak.map(\.value), Array(repeating: 9, count: 10))
        XCTAssertEqual(peak.map(\.t), (0..<10).map { Double($0 * 10) }, "a bucket sits at its first point")
        XCTAssertEqual(m, [1, 98], "markers 1,2,3 share a bucket, 98 and 99 share the last")
        XCTAssertEqual(M.thin(p, [], cap: 10, mean: true).0.map(\.value), Array(repeating: 4.5, count: 10))
        XCTAssertEqual(M.thin(Array(p.prefix(10)), [5], cap: 10, mean: false).0, Array(p.prefix(10)), "few points stay as they are")
        let same = (0..<20).map { _ in CCPoolUsageStats.Point(t: 5, value: 1) }
        XCTAssertEqual(M.thin(same, [], cap: 10, mean: false).0.count, 1, "one instant is one bucket")
    }

    // MARK: what a capped read says (R1484a-s1)

    func testCappedReadIsSaidOnTheCard() async throws {
        let dir = tempDir().appendingPathComponent("usage")
        let m = M(directory: dir, clock: { stNow }, labels: { stLabels },
                  read: { _, _, _ in CCPoolUsageReadResult(rows: [], filesNotRead: 2, truncated: true) })
        await m.reload().value
        XCTAssertEqual(m.shown?.truncated, true)
        XCTAssertEqual(m.shown?.filesNotRead, 2)
        let r = walked(m)
        XCTAssertTrue(r.contains("Only the first \(CCPoolUsageReader.rowsMax.formatted()) rows of this range were read; later ones are not drawn."))
        XCTAssertTrue(r.contains("2 usage files could not be read."))
        let (m2, _) = try rig([:])
        await m2.reload().value
        XCTAssertFalse(walked(m2).contains { $0.contains("Only the first") || $0.contains("could not be read") }, "a complete read says nothing")
    }

    // MARK: hosted

    /// The 14-day card lays out offscreen (no window) inside the pane's room at the smallest and largest UI scale.
    func testCardFitsThePaneWidth() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in [1.0, 0.7] as [CGFloat] {
            ThemeRuntime.scale = scale
            let width = 820 * max(scale, 0.85) - 302 * scale - 2 * sz(16)
            let hc = NSHostingController(rootView: CCPoolUsageStatsSection(model: m).content)
            let fit = hc.sizeThatFits(in: CGSize(width: width, height: 100_000))
            XCTAssertLessThanOrEqual(fit.width, width + 1, "card wider than its room at scale \(scale)")
            XCTAssertGreaterThan(fit.height, 4 * sz(160), "the five charts laid out at scale \(scale)")
        }
    }

    // R1484a-m2: the "Group by" picker is not under a chart's ignored element; the five charts keep label and value.
    // The helper tree (AXTreeSupport.walk) shows a label only, so the value is read here from the node's AX attributes.
    private func axTexts(_ e: Any, _ out: inout [(label: String, texts: [String])], depth: Int = 0) {
        guard depth < 60, let o = e as? NSObject else { return }
        let attrs: [NSAccessibility.Attribute] = [.value, .valueDescription, .description, .help, .title]
        let texts = attrs.compactMap { a in (o.accessibilityAttributeValue(a) as? String) ?? (o.accessibilityAttributeValue(a) as? NSAttributedString)?.string }
        let label = o.responds(to: Selector(("accessibilityLabel"))) ? (o.value(forKey: "accessibilityLabel") as? String) ?? "" : ""
        out.append((label, texts + [o.responds(to: Selector(("accessibilityValue"))) ? "\(o.value(forKey: "accessibilityValue") ?? "")" : ""]))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axTexts(k, &out, depth: depth + 1) }
    }

    /// Facts for the chart value (R1484a-m2): the same label and value modifiers on a plain shape, a Chart, a scroll view,
    /// a stack around a Chart, and a Chart with the image trait, hosted offscreen; what each node serves is printed (AXPROBE
    /// lines). Without a role (AXUnknown) no AXValue is served, a plain Rectangle's neither; the image trait keeps it.
    func testAnElementOnAChartKeepsItsValueProbe() {
        let chart = Chart { BarMark(x: .value("k", "a"), y: .value("v", 1)) }.frame(width: 80, height: 40)
        let view = VStack {
            Rectangle().frame(width: 20, height: 20).accessibilityElement(children: .ignore).accessibilityLabel("probe-1").accessibilityValue("value-1")
            chart.accessibilityElement(children: .ignore).accessibilityLabel("probe-2").accessibilityValue("value-2")
            ScrollView(.horizontal) { Text("x") }.accessibilityElement(children: .ignore).accessibilityLabel("probe-3").accessibilityValue("value-3")
            VStack { chart }.accessibilityElement(children: .ignore).accessibilityLabel("probe-4").accessibilityValue("value-4")
            chart.accessibilityElement(children: .ignore).accessibilityLabel("probe-7").accessibilityValue("value-7").accessibilityAddTraits(.isImage)
            Rectangle().frame(width: 20, height: 20).accessibilityLabel("probe-8").accessibilityValue("value-8")
        }.frame(width: 300)
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(view, CGSize(width: 300, height: 600))
        defer { win.close() }
        let probes = [1, 2, 3, 4, 7, 8]
        let tree = AXTreeSupport.poll(host) { t in probes.allSatisfy { n in t.contains { $0.label == "probe-\(n)" } } }
        XCTAssertFalse(win.isVisible, "never shown")
        for n in tree where n.label.hasPrefix("probe-") || n.value.hasPrefix("value-") {
            print("AXPROBE \(n.role)|\(n.label)|\(n.title)|\(n.value)|\(n.help)|ign \(n.ignored)")
        }
        var nodes: [(label: String, texts: [String])] = []
        axTexts(host, &nodes)
        for n in nodes where n.label.hasPrefix("probe-") { print("AXPROBE-TEXTS \(n.label) \(n.texts)") }
        for n in probes { XCTAssertTrue(tree.contains { $0.label == "probe-\(n)" }, "probe-\(n) in the tree") }
        XCTAssertTrue(nodes.contains { $0.label == "probe-7" && $0.texts.contains("value-7") }, "a chart as an image keeps its value")
    }

    func testGroupByIsInTheHostedTreeAndTheChartsKeepLabelAndValue() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let want = try XCTUnwrap(m.shown).charts(m.grouping)
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(CCPoolUsageStatsSection(model: m).content.frame(width: 600), CGSize(width: 600, height: 2400))
        defer { win.close() }
        let tree = AXTreeSupport.poll(host) { t in t.contains { $0.named(prefix: "Group by") } && want.allSatisfy { c in t.contains { $0.label == c.title } } }
        XCTAssertFalse(win.isVisible, "never shown")
        XCTAssertTrue(tree.contains { !$0.ignored && $0.named(prefix: "Group by") }, "VoiceOver can reach the picker")
        var nodes: [(label: String, texts: [String])] = []
        axTexts(host, &nodes)
        for c in want {
            let mine = nodes.filter { $0.label == c.title }
            XCTAssertTrue(mine.contains { $0.texts.contains(c.summary) }, "\(c.title): \(mine.map(\.texts))")
        }
    }

    // #1896: chart legends wrap inside the card; Swift Charts' own legends are hidden.
    private func longNames(_ n: Int) -> [String] { (0..<n).map { "Example Limited \($0) \u{B7} " + ($0 % 2 == 0 ? "5 h" : "7 d") } }

    /// The legend hosted offscreen at `width`: the chart node (its frame is the card's inner width) and the legend items' nodes.
    private func legendFrames(_ names: [String], width: CGFloat) -> (chart: CGRect, items: [CGRect]) {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let view = VStack(alignment: .leading, spacing: 6) {
            Rectangle().frame(height: 40).accessibilityElement(children: .ignore).accessibilityLabel("chart-probe")
            CCPoolChartLegend(key: CCPoolLegendKey(names))
        }.frame(width: width)
        let (win, host) = AXTreeSupport.hosted(view, CGSize(width: width, height: 800))
        defer { win.close() }
        let tree = AXTreeSupport.poll(host) { t in t.contains { $0.label == "chart-probe" } && names.allSatisfy { n in t.contains { $0.label == n } } }
        XCTAssertFalse(win.isVisible, "never shown")
        let chart = tree.first { $0.label == "chart-probe" }?.frame ?? .zero
        return (chart, names.compactMap { n in tree.first { $0.label == n }?.frame })
    }

    func testLegendWrapsInsideTheCardWithEightLongSeries() {
        let names = longNames(8)
        let (chart, items) = legendFrames(names, width: 360)
        XCTAssertEqual(items.count, 8, "every legend item is in the tree")
        XCTAssertGreaterThan(chart.width, 100)
        for f in items { XCTAssertLessThanOrEqual(f.maxX, chart.maxX + 1, "an item past the card edge: \(f)"); XCTAssertGreaterThanOrEqual(f.minX, chart.minX - 1) }
        XCTAssertGreaterThan(Set(items.map { ($0.minY * 2).rounded() }).count, 1, "more than one line")
    }

    func testOneVeryLongNameStaysInsideTheWidth() {
        let name = String(repeating: "Example Org ", count: 25).prefix(300).description
        let (chart, items) = legendFrames([name], width: 360)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue((items.last?.maxX ?? .infinity) <= chart.maxX + 1, "a 300-character name past the card: \(String(describing: items.last))")
    }

    func testLegendKeyIsTheChartScale() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let s = try XCTUnwrap(m.shown)
        let util = try XCTUnwrap(CCPoolUsageStatsSection.legendKey(0, s))
        XCTAssertEqual(util.names, s.utilization.filter { !$0.points.isEmpty }.map(\.name))
        XCTAssertEqual(util.colours.count, util.names.count)
        XCTAssertEqual(try XCTUnwrap(CCPoolUsageStatsSection.legendKey(1, s)).names, M.kinds)
        XCTAssertTrue(CCPoolUsageStatsSection.legendKey(3, s) == nil, "the table has no legend")
        XCTAssertEqual(try XCTUnwrap(CCPoolUsageStatsSection.legendKey(4, s)).names, Array(NSOrderedSet(array: s.finish.flatMap { ["\($0.model) median", "\($0.model) 90th"] })) as? [String], "one entry per series, in first-drawn order (finish has a row per model per day)")
        XCTAssertEqual(CCPoolLegendKey(["a", "b", "a"]).names, ["a", "b"], "a repeated name is one entry")
    }

    // The pane hosts the card on the pane model's record folder.
    func testPaneModelPointsTheCardAtItsRecordFolder() throws {
        let r = try ccpoolPaneRig()
        XCTAssertEqual(r.model.usageStats.directory, r.store.usageDirectory)
        XCTAssertTrue(r.model.usageStats === r.model.usageStats, "one model for the life of the pane")
        try r.add(["Example Org A"])
        let id = try XCTUnwrap(r.store.snapshot.accounts["Example Org A"]?.id)
        XCTAssertEqual(r.model.usageStats.labels(), [id: "Example Org A"])
    }

    // #1897: the Tokens by kind axis reads K / M / B in every locale.
    func testAxisTokensAreCompactEnglish() {
        let f = CCPoolUsageStatsSection.axisTokens
        let want: [(Double, String)] = [(0, "0"), (999, "999"), (1_000, "1K"), (900_000, "900K"), (50_000_000, "50M"), (150_000_000, "150M"),
                                        (1_500_000_000, "1.5B"), (-5, "0"), (.nan, "0"), (.infinity, "0")]
        for (v, s) in want { XCTAssertEqual(f(v), s, "\(v)") }
    }

    func testTokenChartAxisHasNoENotationUnderACommaLocale() async throws {
        let (m, _) = try fortnight()
        await m.select(.fortnight)?.value
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(CCPoolUsageStatsSection(model: m).content.frame(width: 600).environment(\.locale, Locale(identifier: "bg_BG")), CGSize(width: 600, height: 2400))
        defer { win.close() }
        _ = AXTreeSupport.poll(host) { t in t.contains { $0.label == "Tokens by kind" } }
        var nodes: [(label: String, texts: [String])] = []
        axTexts(host, &nodes)
        let all = nodes.flatMap(\.texts)
        XCTAssertFalse(all.contains { $0.range(of: "[0-9][,.]?[0-9]*E[0-9]", options: .regularExpression) != nil }, "\(all)")
        // Axis labels may not be reachable in the AX tree; the M check only applies when any K/M/B label is.
        if all.contains(where: { $0.range(of: "^[0-9.]+[KB]$", options: .regularExpression) != nil }) || all.contains(where: { $0.hasSuffix("M") }) {
            XCTAssertTrue(all.contains { $0.range(of: "^[0-9.]+M$", options: .regularExpression) != nil }, "\(all)")
        }
    }
}
