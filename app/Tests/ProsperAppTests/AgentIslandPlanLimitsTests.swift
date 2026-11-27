import SwiftUI
import AppKit
import XCTest
@testable import ProsperApp

/// #1898: the plan usage line's popover, every pool account's limits and reset times, read only. Fakes only: the
/// controller's seams are literals, no panel is built or ordered (`showsPanel = false`), no monitor is installed, no
/// popover is shown (its content view is hosted alone in a never-shown window); the runtime row builds its own pool on
/// a tempDir() with memory secrets and binds and dials nothing.
final class AgentIslandPlanLimitsTests: XCTestCase {
    private let now: Double = 1_800_000_000   // Fri 08:00 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let claims: [(claim: String, name: String)] = [("five_hour", "5h"), ("seven_day", "week"), ("seven_day_opus", "opus"),
                                                           ("seven_day_sonnet", "sonnet"), ("seven_day_overage_included", "fable")]

    private func account(_ label: String, current: Bool = false, util: [String: Double], at: Double? = nil,
                         reset: [String: Int] = [:], cooldown: [String: Int] = [:]) -> AgentPlanLimits.Account {
        AgentPlanLimits.Account(label: label, isCurrent: current, util: util, at: at ?? now - 60, reset: reset,
                                cooldown: cooldown, claims: claims, now: now)
    }

    // MARK: - The pure builder

    func testAccountsAreSortedMostUrgentFirstTiesByEarliestReset() {
        let a = account("a", util: ["five_hour": 0.5], reset: ["five_hour": Int(now) + 100])
        let b = account("b", util: ["five_hour": 0.2, "seven_day": 0.9])
        let c = account("c", util: ["seven_day": 0.5], reset: ["seven_day": Int(now) + 50])
        let d = AgentPlanLimits.Account(label: "d", isCurrent: false, util: [:], at: nil, reset: [:], cooldown: [:], claims: claims, now: now)
        let l = AgentPlanLimits(pool: nil, accounts: [d, a, c, b])
        XCTAssertEqual(l.accounts.map(\.label), ["b", "c", "a", "d"],
                       "highest use of any limit first; equal use: the earlier reset first; no data last")
    }

    func testAStaleClaimIsDroppedAloneByTheLinesRule() throws {
        let a = account("a", util: ["five_hour": 0.9, "seven_day": 0.3, "seven_day_opus": 0.7], at: now - 5 * 3600,
                        reset: ["seven_day": Int(now) - 1])
        XCTAssertEqual(a.limits.map(\.name), ["opus"],
                       "5h: older than its window with no reset; week: its reset passed; opus: a 7-day window still open")
        let fresh = account("f", util: ["five_hour": 0.9], at: now - 5 * 3600 + 1)
        XCTAssertEqual(fresh.limits.first?.util, 0.9, "one second inside the window: kept")
        let none = account("n", util: ["five_hour": 0.9], reset: ["five_hour": Int(now)])
        XCTAssertTrue(none.limits.isEmpty, "the only value stale: no data")
        XCTAssertEqual(AgentPlanLimits.spoken(none, now: now, timeZone: utc), "n, no recent data, updated 1 min ago")
    }

    func testBenchedOnlyWhileACooldownIsInForce() {
        let benched = account("a", util: ["five_hour": 0.95],
                              cooldown: ["five_hour": Int(now) + 6000, "seven_day": Int(now) + 9000, "seven_day_opus": Int(now) - 5])
        XCTAssertEqual(benched.benchedUntil, Int(now) + 6000, "the earliest cooldown still in force, as the pane's limited until")
        XCTAssertEqual(AgentPlanLimits.benchedText(Int(now) + 6000, timeZone: utc), "benched until 09:40")
        let over = account("b", util: ["five_hour": 0.95], cooldown: ["five_hour": Int(now)])
        XCTAssertTrue(over.benchedUntil == nil, "a cooldown that ended: not benched")
    }

    func testModelWeekliesOnlyWhenReported() {
        XCTAssertEqual(account("a", util: ["five_hour": 0.1, "seven_day": 0.2]).limits.map(\.name), ["5h", "week"])
        XCTAssertEqual(account("b", util: ["seven_day_overage_included": 0.4, "five_hour": 0.1, "seven_day_sonnet": 0.3]).limits.map(\.name),
                       ["5h", "sonnet", "fable"], "in the pool's display order")
    }

    func testRelativeTimeWords() {
        XCTAssertEqual(AgentPlanLimits.duration(0), "0 min")
        XCTAssertEqual(AgentPlanLimits.duration(-30), "0 min", "a reset just passed never reads negative")
        XCTAssertEqual(AgentPlanLimits.duration(59 * 60 + 59), "59 min")
        XCTAssertEqual(AgentPlanLimits.duration(2 * 3600 + 14 * 60), "2 h 14 min")
        XCTAssertEqual(AgentPlanLimits.duration(3 * 86400), "3 d")
        XCTAssertEqual(AgentPlanLimits.duration(.nan), "0 min")
        XCTAssertEqual(AgentPlanLimits.duration(2 * 3600 + 14 * 60, spoken: true), "2 hours 14 minutes")
        XCTAssertEqual(AgentPlanLimits.duration(60, spoken: true), "1 minute")
        XCTAssertEqual(AgentPlanLimits.updatedText(now - 20, now: now), "updated just now")
        XCTAssertEqual(AgentPlanLimits.updatedText(now - 180, now: now), "updated 3 min ago")
    }

    func testResetWordsAndTheSpokenRow() throws {
        let a = account("alpha", current: true, util: ["five_hour": 0.15, "seven_day": 0.99], at: now - 180,
                        reset: ["five_hour": Int(now) + 8040, "seven_day": 1_800_259_200])
        let first = try XCTUnwrap(a.limits.first)
        XCTAssertEqual(AgentPlanLimits.resetText(first, now: now, timeZone: utc), "2 h 14 min \u{00B7} Fri 10:14")
        XCTAssertEqual(AgentPlanLimits.spoken(a, now: now, timeZone: utc),
                       "alpha, 5 hour 15 percent, resets in 2 hours 14 minutes, Friday 10:14; "
                       + "week 99 percent, resets in 3 days, Monday 08:00, updated 3 min ago")
    }

    // MARK: - #1915: the redesign's words and its split

    func testCardAgeDropsTheUpdatedWordTheSpokenRowKeepsIt() {
        XCTAssertEqual(AgentPlanLimits.ago(now - 20, now: now), "just now")
        XCTAssertEqual(AgentPlanLimits.ago(now - 300, now: now), "5 min ago")
        XCTAssertEqual(AgentPlanLimits.updatedText(now - 300, now: now), "updated 5 min ago")
    }

    func testPoolSplitsIntoOneAlignedPartPerWindow() {
        XCTAssertEqual(AgentPlanLimits.poolParts("5h 292% (more at Tue 11:20) \u{00B7} week 248% (more at Wed 16:00) \u{00B7} opus 40%"),
                       [.init(name: "5h", free: "292%", more: "more at Tue 11:20"), .init(name: "week", free: "248%", more: "more at Wed 16:00"),
                        .init(name: "opus", free: "40%", more: nil)])
        XCTAssertEqual(AgentPlanLimits.poolParts("5h 60%"), [.init(name: "5h", free: "60%", more: nil)])
        XCTAssertEqual(AgentPlanLimits.poolParts("odd"), [.init(name: "odd", free: "", more: nil)], "no space: all name, nothing dropped")
        XCTAssertEqual(AgentPlanLimits.poolParts(""), [])
    }

    /// The parts from the pane's own words: a change to poolText's format turns this row red, not just the popover.
    func testPoolPartsReadThePanesPoolText() throws {
        let cells = [CCPoolCore.PoolCell(claim: "five_hour", free: 2.92, growsAt: Int(now) + 3600),
                     CCPoolCore.PoolCell(claim: "seven_day", free: 2.48, growsAt: Int(now) + 3 * 86400),
                     CCPoolCore.PoolCell(claim: "seven_day_opus", free: 0.4, growsAt: nil)]
        let pool = try XCTUnwrap(CCPoolPaneModel.poolText(cells, timeZone: utc))
        XCTAssertEqual(AgentPlanLimits.poolParts(pool),
                       [.init(name: "5h", free: "292%", more: "more at Fri 09:00"), .init(name: "week", free: "248%", more: "more at Mon 08:00"),
                        .init(name: "opus", free: "40%", more: nil)])
    }

    @MainActor func testAccountsWithoutLimitsDrawTheCompactRowAfterTheCards() {
        let alpha = account("alpha", current: true, util: ["five_hour": 0.15])
        let beta = account("beta", util: ["five_hour": 0.95], cooldown: ["five_hour": Int(now) + 6000])
        let gamma = AgentPlanLimits.Account(label: "gamma", isCurrent: false, util: [:], at: nil, reset: [:], cooldown: [:],
                                            claims: claims, now: now)
        let delta = AgentPlanLimits.Account(label: "delta", isCurrent: false, util: [:], at: nil, reset: [:],
                                            cooldown: ["five_hour": Int(now) + 6000], claims: claims, now: now)
        XCTAssertEqual(AgentPlanLimits.compactStatus(alpha, timeZone: utc), nil, "limits: a card")
        XCTAssertEqual(AgentPlanLimits.compactStatus(beta, timeZone: utc), nil, "benched with limits: still a card")
        XCTAssertEqual(AgentPlanLimits.compactStatus(gamma, timeZone: utc), "no recent data")
        XCTAssertEqual(AgentPlanLimits.compactStatus(delta, timeZone: utc), "benched until 09:40")
        let split = AgentPlanLimitsView.split(AgentPlanLimits(pool: nil, accounts: [gamma, alpha, delta, beta]), timeZone: utc)
        XCTAssertEqual(split.cards.map(\.label), ["beta", "alpha"], "most urgent first")
        XCTAssertEqual(split.compact.map(\.account.label), ["delta", "gamma"], "the order kept")
        XCTAssertEqual(split.compact.map(\.status), ["benched until 09:40", "no recent data"])
    }

    /// #1947: every reset text is drawn at 10 pt with no scaling, so the widest real one fits its column as measured.
    @MainActor func testWidestResetTextFitsItsColumnAtTenPoints() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        func width(_ reset: Int, now n: Double) -> CGFloat {
            let l = AgentPlanLimits.Limit(claim: "five_hour", name: "5h", util: 0.5, reset: reset, runsOut: nil)
            let t = AgentPlanLimits.resetText(l, now: n, timeZone: utc) ?? ""
            return ceil((t as NSString).size(withAttributes: [.font: font]).width)
        }
        // 23 h 59 min (the longest hour form) and 6 d 23 h (the longest day form of a 7 day window), each ending at 23:59 on every weekday name.
        let spans: [Int] = [23 * 3600 + 59 * 60, 6 * 86400 + 23 * 3600]
        let midnight = Int(now) - 8 * 3600
        var widest: CGFloat = 0
        for k in 0..<7 {
            let target = midnight + k * 86400 + 23 * 3600 + 59 * 60
            for span in spans { widest = max(widest, width(target, now: Double(target - span))) }
        }
        XCTAssertLessThanOrEqual(widest, AgentPlanLimitsView.resetWidth, "widest \(widest)")
        let expected: CGFloat = 360 - 44 - 42 - 80 - 38 - 18
        XCTAssertEqual(AgentPlanLimitsView.resetWidth, expected)
    }

    /// #1957: a weekly crossing days away names the limit, the distance and the weekday.
    func testWeeklyPaceTextNamesTheWeekAndTheDay() {
        let l = AgentPlanLimits.Limit(claim: "seven_day", name: "week", util: 0.5, reset: Int(now) + 5 * 86400, runsOut: Int(now) + 86400 + 3 * 3600)
        XCTAssertEqual(AgentPlanLimits.runsOutText(l, now: now, timeZone: utc), "week runs out in ~1 d 3 h \u{00B7} Sat 11:00 at this pace")
        let a = AgentPlanLimits.Account(label: "alpha", isCurrent: false, util: [:], at: nil, reset: [:], cooldown: [:], claims: claims, now: now)
        var b = a; b.limits = [l]
        XCTAssertTrue(AgentPlanLimits.spoken(b, now: now, timeZone: utc).contains("week runs out at this pace in about 1 day 3 hours, Saturday 11:00"))
    }

    /// #1957: the widest real pace line (a 6 d 23 h week crossing, a 4 h 59 min 5h crossing, each at 23:59) fits its line at 10 pt, no scaling.
    @MainActor func testWidestPaceTextFitsItsLineAtTenPoints() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        var widest: CGFloat = 0
        for k in 0..<7 {
            let target = Int(now) - 8 * 3600 + k * 86400 + 23 * 3600 + 59 * 60
            for (name, span) in [("week", 6 * 86400 + 23 * 3600), ("5h", 4 * 3600 + 59 * 60)] {
                let l = AgentPlanLimits.Limit(claim: "x", name: name, util: 0.5, reset: target + 3600, runsOut: target)
                let t = AgentPlanLimits.runsOutText(l, now: Double(target - span), timeZone: utc) ?? ""
                widest = max(widest, ceil((t as NSString).size(withAttributes: [.font: font]).width))
            }
        }
        XCTAssertLessThanOrEqual(widest, AgentPlanLimitsView.paceWidth, "widest \(widest)")
    }

    @MainActor func testBarIsDangerFromNinetyPercent() {
        XCTAssertNotEqual(Neon.magenta, Neon.blue, "the row needs two colours")
        XCTAssertEqual(AgentPlanLimitsView.barColor(0.9), Neon.magenta)
        XCTAssertEqual(AgentPlanLimitsView.barColor(1.2), Neon.magenta)
        XCTAssertEqual(AgentPlanLimitsView.barColor(0.89), Neon.blue)
    }

    @MainActor func testCardsAndCompactRowsSpeakTheSameWords() {
        let alpha = account("alpha", current: true, util: ["five_hour": 0.15], at: now - 180, reset: ["five_hour": Int(now) + 8040])
        let delta = AgentPlanLimits.Account(label: "delta", isCurrent: false, util: [:], at: nil, reset: [:],
                                            cooldown: ["five_hour": Int(now) + 6000], claims: claims, now: now)
        let spoken = ["alpha, 5 hour 15 percent, resets in 2 hours 14 minutes, Friday 10:14, updated 3 min ago",
                      "delta, no recent data, benched until 09:40"]
        XCTAssertEqual([alpha, delta].map { AgentPlanLimits.spoken($0, now: now, timeZone: utc) }, spoken, "#1898's words")
        let view = AgentPlanLimitsView(limits: AgentPlanLimits(pool: "5h 85% (more at Fri 09:00)", accounts: [alpha, delta]), now: now, timeZone: utc)
        let tree = AXTreeSupport.tree(view, CGSize(width: 340, height: 400)) { t in spoken.allSatisfy { s in t.contains { $0.reads(s) } } }
        for s in spoken { XCTAssertTrue(tree.contains { $0.reads(s) }, "one element per account: \(s)") }
        XCTAssertTrue(tree.contains { $0.reads("Free across all accounts: 5h 85% (more at Fri 09:00)") }, "the pool speaks one sentence")
    }

    // MARK: - #1899: the pace, "<name> runs out in ~<time> · <day> at this pace" before the reset

    private func pace(_ points: [(dt: Double, u: Double)], r: Int? = nil) -> [AgentPlanLimits.PaceSample] {
        let reset = Double(r ?? Int(now) + 7200)
        return points.map { AgentPlanLimits.PaceSample(t: now + $0.dt, u: $0.u, r: reset) }
    }

    /// 0.5 at -50 min rising 0.05 every 10 min to 0.75 now: 100% at now + 50 min.
    private let rising: [(dt: Double, u: Double)] = [(-3000, 0.5), (-2400, 0.55), (-1800, 0.6), (-1200, 0.65), (-600, 0.7), (0, 0.75)]

    func testPaceRisingCrossesBeforeTheReset() {
        XCTAssertEqual(AgentPlanLimits.runsOut(pace(rising), reset: Int(now) + 7200, now: now), Int(now) + 3000)
        XCTAssertEqual(AgentPlanLimits.runsOut(pace(rising).reversed(), reset: Int(now) + 7200, now: now), Int(now) + 3000,
                       "any order")
    }

    func testPaceCrossingAtOrAfterTheResetShowsNothing() {
        XCTAssertTrue(AgentPlanLimits.runsOut(pace(rising, r: Int(now) + 2000), reset: Int(now) + 2000, now: now) == nil,
                      "the limit resets before it would run out")
        XCTAssertTrue(AgentPlanLimits.runsOut(pace(rising, r: Int(now) + 3000), reset: Int(now) + 3000, now: now) == nil,
                      "at the reset itself: nothing")
    }

    func testPaceFlatOrFallingShowsNothing() {
        XCTAssertTrue(AgentPlanLimits.runsOut(pace(rising.map { (dt: $0.dt, u: 0.6) }), reset: Int(now) + 7200, now: now) == nil, "flat")
        // Over 100% and falling toward it: a line that ignores the sign would cross 100% in the future.
        let falling: [(dt: Double, u: Double)] = [(-3000, 1.3), (-2400, 1.26), (-1800, 1.22), (-1200, 1.18), (-600, 1.14), (0, 1.1)]
        XCTAssertTrue(AgentPlanLimits.runsOut(pace(falling), reset: Int(now) + 7200, now: now) == nil, "falling")
    }

    func testPaceNeedsTwoSamplesTenMinutesApart() {
        XCTAssertTrue(AgentPlanLimits.runsOut(pace([(0, 0.9)]), reset: Int(now) + 7200, now: now) == nil, "one sample")
        XCTAssertTrue(AgentPlanLimits.runsOut(pace([(-540, 0.5), (0, 0.9)]), reset: Int(now) + 7200, now: now) == nil, "9 min of data")
        XCTAssertEqual(AgentPlanLimits.runsOut(pace([(-600, 0.5), (0, 0.9)]), reset: Int(now) + 7200, now: now), Int(now) + 150,
                       "10 min of data: shown")
        XCTAssertTrue(AgentPlanLimits.runsOut(pace([(-4000, 0.1), (0, 0.9)]), reset: Int(now) + 7200, now: now) == nil,
                      "a sample older than an hour is not read")
    }

    func testPaceIgnoresSamplesFromBeforeTheLastReset() {
        let old = pace([(-3000, 0.9), (-2400, 0.95)], r: Int(now) - 1800)
        let cur = pace([(-1800, 0.1), (-1200, 0.3), (-600, 0.5), (0, 0.7)])
        XCTAssertEqual(AgentPlanLimits.runsOut(old + cur, reset: Int(now) + 7200, now: now), Int(now) + 900,
                       "only the window since the reset changed; with the old window the line would fall")
        XCTAssertTrue(AgentPlanLimits.runsOut(old, reset: Int(now) + 7200, now: now) == nil, "no sample under this reset")
    }

    @MainActor func testPaceWordsInTheRowAndItsSpokenLabel() throws {
        let a = account("alpha", current: true, util: ["five_hour": 0.75, "seven_day": 0.2], at: now - 60,
                        reset: ["five_hour": Int(now) + 7200, "seven_day": Int(now) + 3 * 86400])
        let flat = pace(rising.map { (dt: $0.dt, u: 0.2) }, r: Int(now) + 3 * 86400)
        let limits = AgentPlanLimits(pool: nil, accounts: [a]).withPace(["alpha": ["five_hour": pace(rising), "seven_day": flat],
                                                                         "other": ["five_hour": pace(rising)]], now: now)
        let row = try XCTUnwrap(limits.accounts.first)
        XCTAssertEqual(row.limits.map(\.runsOut), [Int(now) + 3000, nil])
        XCTAssertEqual(row.limits.first.flatMap { AgentPlanLimits.runsOutText($0, now: now, timeZone: utc) },
                       "5h runs out in ~50 min \u{00B7} Fri 08:50 at this pace")
        let spoken = AgentPlanLimits.spoken(row, now: now, timeZone: utc)
        XCTAssertEqual(spoken, "alpha, 5 hour 75 percent, resets in 2 hours, Friday 10:00, 5 hour runs out at this pace in about 50 minutes, Friday 08:50; "
                       + "week 20 percent, resets in 3 days, Monday 08:00, updated 1 min ago")
        let tree = AXTreeSupport.tree(AgentPlanLimitsView(limits: limits, now: now, timeZone: utc), CGSize(width: 340, height: 300)) { t in
            t.contains { $0.reads(spoken) }
        }
        XCTAssertTrue(tree.contains { $0.reads(spoken) }, "the popover row speaks the pace")
        XCTAssertTrue(AgentPlanLimits(pool: nil, accounts: [a]).withPace([:], now: now).accounts.first?.limits.allSatisfy { $0.runsOut == nil } == true,
                      "no samples: no words")
    }

    func testPaceSamplesMapIdsToLabelsAndNeedUseAndReset() {
        func row(_ acct: String, _ lim: [String: CCPoolUsageEntry.Claim]) -> CCPoolUsageEntry {
            CCPoolUsageEntry(t: now, acct: acct, model: "m", sess: nil, agent: nil, path: "messages", st: 200, ms: 1, done: true, qc: false,
                             att: 1, thr: 0, mv: false, routed: "r", tokens: nil, lim: lim)
        }
        let s = CCPoolRuntime.paceSamples([row("id-a", ["five_hour": .init(u: 0.4, r: now + 60), "seven_day": .init(u: 0.2, r: nil)]),
                                           row("id-gone", ["five_hour": .init(u: 0.9, r: now + 60)])],
                                          labels: ["id-a": "alpha"])
        XCTAssertEqual(s, ["alpha": ["five_hour": [.init(t: now, u: 0.4, r: now + 60)]]],
                       "a removed account and a claim without a reset are left out")
    }

    // MARK: - The pool's accessor

    @MainActor func testRuntimeReadsEveryAccountWithTheCurrentMarked() throws {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let defaults: UserDefaults = XCTestDefaults(suiteName: "prosper-plan-limits-\(UUID().uuidString)")!
        XCTAssertTrue(defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: defaults, probeBase: cfg.upstream,
                               logger: CCPoolCapturingLogger())
        let t = Date().timeIntervalSince1970
        XCTAssertTrue(rt.planLimits(now: t).accounts.isEmpty, "no account")
        let idA = try rt.store.addAccount(label: "alpha", token: "example-token-a", secrets: rt.secrets)
        let idB = try rt.store.addAccount(label: "beta", token: "example-token-b", secrets: rt.secrets)
        _ = try rt.store.addAccount(label: "gamma", token: "example-token-c", secrets: rt.secrets)
        rt.store.mutate {
            $0.current = "beta"
            // #1898 CI: each sample's claims carry a reset, as a relayed reply records them (CCPoolConnection recordResets).
            $0.accounts["alpha"]?.reset = ["five_hour": Int(t) + 7200]
            $0.accounts["beta"]?.reset = ["five_hour": Int(t) + 3600, "seven_day": Int(t) + 3 * 86400]
            $0.accounts["gamma"]?.cooldown = ["five_hour": Int(t) + 600]
        }
        rt.store.recordUsage(id: idA, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.9"]).limits)
        rt.store.recordUsage(id: idB, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.25",
                                                                      "anthropic-ratelimit-unified-7d-utilization": "0.5"]).limits)
        let l = rt.planLimits(now: t)
        XCTAssertEqual(l.accounts.map(\.label), ["alpha", "beta", "gamma"], "most urgent first, no data last")
        XCTAssertEqual(l.accounts.map(\.isCurrent), [false, true, false])
        let beta = try XCTUnwrap(l.accounts.first { $0.label == "beta" })
        XCTAssertEqual(beta.limits.map(\.name), ["5h", "week"])
        XCTAssertEqual(beta.limits.first?.reset, Int(t) + 3600)
        let gamma = try XCTUnwrap(l.accounts.last)
        XCTAssertTrue(gamma.limits.isEmpty && gamma.sampleAt == nil, "no sample: no recent data")
        XCTAssertEqual(gamma.benchedUntil, Int(t) + 600)
        // The pane's words for the pane's cells: 5h alpha 10% + beta 75% free, more when beta's 5h resets; week beta 50%
        // free, more when its week resets; gamma (no sample, benched) adds nothing.
        let at = { CCPoolPaneModel.timeText($0, timeZone: rt.model.timeZone) }
        XCTAssertEqual(l.pool, "5h 85% (more at \(at(Int(t) + 3600))) \u{00B7} week 50% (more at \(at(Int(t) + 3 * 86400)))")
    }

    // #1907: an account whose sample has no reset (a probe without reset headers): its share is used in the pool line for
    // its window after the sample, then rolled over (free), the rows' own stale rule.
    @MainActor func testRuntimePoolCountsANoResetSampleUsedWithinItsWindow() throws {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let defaults: UserDefaults = XCTestDefaults(suiteName: "prosper-plan-limits-\(UUID().uuidString)")!
        XCTAssertTrue(defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: defaults, probeBase: cfg.upstream,
                               logger: CCPoolCapturingLogger())
        let id = try rt.store.addAccount(label: "api", token: "example-token-a", secrets: rt.secrets)
        rt.store.recordUsage(id: id, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.4"]).limits)
        let at = try XCTUnwrap(rt.store.usageSample("api")?.at)
        XCTAssertEqual(rt.planLimits(now: at + 60).pool, "5h 60%", "fresh: the share is used")
        let stale = rt.planLimits(now: at + AgentPlanUsage.sessionWindow + 1)
        XCTAssertTrue(stale.accounts.first?.limits.isEmpty ?? false, "the row drops the stale share")
        XCTAssertEqual(stale.pool, "5h 100%", "the pool counts it rolled over")
    }

    // MARK: - The controller: read on open, then only on a change of the line

    @MainActor private func controller(_ usage: @escaping () -> AgentPlanUsage?, limits: @escaping () -> AgentPlanLimits?) -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.center = NotificationCenter()
        c.io = AgentPromptIO(read: { _ in "" }, status: { _ in "idle" }, send: { _, _ in })
        c.controlDch = { nil }
        c.historyDirs = { [] }
        c.seedDirs = { [] }
        c.listSessions = { _ in [] }
        c.readLiveRecords = { _ in [] }
        c.monitorClicks = { _ in "global" }
        c.monitorOwnClicks = { _ in "local" }
        c.removeMonitor = { _ in }
        c.planUsage = { _, _ in usage() }
        c.planLimits = { _ in limits() }
        c.openPoolSettings = {}
        let geometry = AgentIslandGeometry.make(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            safeTop: 32)
        let store = AgentIslandStore(geometry: geometry, sort: .name, sidekickPattern: "")
        store.sessions = [AgentSession(key: AgentSessionKey(dir: "/Users/example/d", name: "api"), alias: "", activity: 0,
                                       state: .idle, agents: 0)]
        c.store = store
        return c
    }

    @MainActor func testReadOnOpenAndOnlyWhenTheLineChangesWhileOpen() throws {
        let saved = Preferences.defaults.object(forKey: "agentIslandShowPlanUsage")
        defer { if let v = saved { Preferences.defaults.set(v, forKey: "agentIslandShowPlanUsage") } else { Preferences.defaults.removeObject(forKey: "agentIslandShowPlanUsage") } }
        Preferences.agentIslandShowPlanUsage = true
        let t = Date().timeIntervalSince1970
        var usage = AgentPlanUsage(util: ["five_hour": 0.42], at: t, reset: [:], now: t)
        let value = AgentPlanLimits(pool: nil, accounts: [account("api", current: true, util: ["five_hour": 0.42])])
        let c = controller({ usage }, limits: { value })
        let store = try XCTUnwrap(c.store)
        c.showPlanLimits(true)
        XCTAssertEqual(c.planLimitsReads, 0, "collapsed: no line, no read")
        c.setExpanded(true)
        XCTAssertEqual(c.planLimitsReads, 0, "opening the island does not read the popover")
        c.showPlanLimits(true)
        XCTAssertEqual(c.planLimitsReads, 1)
        XCTAssertEqual(store.planLimits, value)
        for _ in 0..<5 { c.readPlanUsage() }
        XCTAssertEqual(c.planLimitsReads, 1, "the same line on each tick: no rebuild")
        usage = AgentPlanUsage(util: ["five_hour": 0.5], at: t, reset: [:], now: t)
        c.readPlanUsage()
        XCTAssertEqual(c.planLimitsReads, 2, "the line moved while open: one re-read")
        c.showPlanLimits(false)
        XCTAssertTrue(store.planLimits == nil)
        usage = AgentPlanUsage(util: ["five_hour": 0.6], at: t, reset: [:], now: t)
        c.readPlanUsage()
        XCTAssertEqual(c.planLimitsReads, 2, "closed: a change reads nothing")
        c.showPlanLimits(true)
        XCTAssertEqual(c.planLimitsReads, 3)
        usage = nil
        c.readPlanUsage()
        XCTAssertTrue(store.planLimits == nil, "the line went: the popover goes with it")
        XCTAssertEqual(c.planLimitsReads, 3)
        usage = AgentPlanUsage(util: ["five_hour": 0.6], at: t, reset: [:], now: t)
        c.readPlanUsage()
        c.showPlanLimits(true)
        c.setExpanded(false)
        XCTAssertTrue(store.planLimits == nil, "collapsing closes it")
    }

    @MainActor func testPaceIsReadOncePerOpenOffTheSeamAndApplied() async throws {
        let saved = Preferences.defaults.object(forKey: "agentIslandShowPlanUsage")
        defer { if let v = saved { Preferences.defaults.set(v, forKey: "agentIslandShowPlanUsage") } else { Preferences.defaults.removeObject(forKey: "agentIslandShowPlanUsage") } }
        Preferences.agentIslandShowPlanUsage = true
        let t = Date().timeIntervalSince1970
        var usage = AgentPlanUsage(util: ["five_hour": 0.75], at: t, reset: [:], now: t)
        let reset = Int(t) + 7200
        let value = AgentPlanLimits(pool: nil, accounts: [AgentPlanLimits.Account(
            label: "api", isCurrent: true, util: ["five_hour": 0.75], at: t, reset: ["five_hour": reset], cooldown: [:], claims: claims, now: t)])
        let c = controller({ usage }, limits: { value })
        c.planPace = { n in
            ["api": ["five_hour": (0...5).map { (i: Int) -> AgentPlanLimits.PaceSample in
                AgentPlanLimits.PaceSample(t: n - Double(5 - i) * 600, u: 0.5 + Double(i) * 0.05, r: Double(reset))
            }]]
        }
        let store = try XCTUnwrap(c.store)
        c.setExpanded(true)
        c.showPlanLimits(true)
        XCTAssertEqual(c.planPaceReads, 1)
        for _ in 0..<200 where store.planLimits?.accounts.first?.limits.first?.runsOut == nil { await Task.yield() }
        let out = try XCTUnwrap(store.planLimits?.accounts.first?.limits.first?.runsOut)
        XCTAssertTrue(abs(Double(out) - (t + 3000)) <= 2, "the seam's samples projected: \(out)")
        usage = AgentPlanUsage(util: ["five_hour": 0.8], at: t, reset: [:], now: t)
        c.readPlanUsage()
        XCTAssertEqual(c.planLimitsReads, 2)
        XCTAssertEqual(c.planPaceReads, 1, "a re-read while open reuses the samples")
        XCTAssertTrue(store.planLimits?.accounts.first?.limits.first?.runsOut != nil, "and keeps the words at once")
        c.showPlanLimits(false)
        c.showPlanLimits(true)
        XCTAssertEqual(c.planPaceReads, 2, "a new open reads afresh")
    }

    @MainActor func testPoolOffNeverOpens() throws {
        let c = controller({ nil }, limits: { XCTFail("never read with the pool off"); return nil })
        c.setExpanded(true)
        c.showPlanLimits(true)
        XCTAssertTrue(c.store?.planLimits == nil)
        XCTAssertEqual(c.planLimitsReads, 0)
    }

    // MARK: - The views (hosted in a never-shown window)

    @MainActor private func lineStore(_ usage: AgentPlanUsage?) -> AgentIslandStore {
        let geometry = AgentIslandGeometry.make(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
            safeTop: 32)
        let store = AgentIslandStore(geometry: geometry, sort: .name, sidekickPattern: "")
        store.history = [DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "work"), cwd: "/src", updated: 1, ended: 1,
                                          end: "stopped", pinned: false, file: "work")]
        store.planUsage = usage
        return store
    }

    @MainActor func testTheLineIsAButtonWithItsHelpAsLabel() throws {
        let usage = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.15, "seven_day": 0.99], at: now, reset: [:], now: now))
        let help = usage.help()
        let tree = AXTreeSupport.tree(AgentIslandView(store: lineStore(usage)).tabRow, CGSize(width: 600, height: 30)) { t in
            t.contains { $0.role == "AXButton" && $0.names.contains(help) }
        }
        let line = try XCTUnwrap(tree.first { $0.role == "AXButton" && $0.names.contains(help) })
        XCTAssertTrue(line.help.contains(AgentIslandView.planLimitsHint), "the hint: \(line.help)")
    }

    @MainActor func testPoolOffDrawsNoLineButton() {
        let tree = AXTreeSupport.tree(AgentIslandView(store: lineStore(nil)).tabRow, CGSize(width: 600, height: 30)) { t in
            t.contains { $0.reads("History (1)") }
        }
        XCTAssertTrue(tree.contains { $0.reads("History (1)") }, "the row was drawn")
        XCTAssertFalse(tree.contains { n in n.names.contains { $0.contains("Claude plan usage") } }, "no line, no button")
    }

    @MainActor func testPopoverReadsEveryAccountAndHoldsOnlyTheSettingsLink() throws {
        let alpha = account("alpha", current: true, util: ["five_hour": 0.15, "seven_day": 0.99], at: now - 180,
                            reset: ["five_hour": Int(now) + 8040, "seven_day": 1_800_259_200])
        let beta = account("beta", util: ["five_hour": 0.95], cooldown: ["five_hour": Int(now) + 6000])
        let gamma = AgentPlanLimits.Account(label: "gamma", isCurrent: false, util: [:], at: nil, reset: [:], cooldown: [:],
                                            claims: claims, now: now)
        let limits = AgentPlanLimits(pool: "5h 62% \u{00B7} week 18%", accounts: [alpha, beta, gamma])
        let spoken = limits.accounts.map { AgentPlanLimits.spoken($0, now: now, timeZone: utc) }
        XCTAssertTrue(spoken.contains { $0.contains("resets in 2 hours 14 minutes") })
        var opened = 0
        let view = AgentPlanLimitsView(limits: limits, now: now, timeZone: utc, onSettings: { opened += 1 })
        let tree = AXTreeSupport.tree(view, CGSize(width: 340, height: 400)) { t in spoken.allSatisfy { s in t.contains { $0.reads(s) } } }
        for s in spoken { XCTAssertTrue(tree.contains { $0.reads(s) }, "one element per account: \(s)") }
        XCTAssertTrue(tree.contains { $0.reads("Free across all accounts: 5h 62% \u{00B7} week 18%") }, "the pool on top")
        let buttons = tree.filter { $0.role == "AXButton" }
        XCTAssertEqual(buttons.count, 1, "read only: the settings link is the one control; got \(buttons.map(\.names))")
        XCTAssertTrue(buttons.first?.reads(AgentPlanLimits.settingsLink) == true)
        XCTAssertEqual(opened, 0, "drawing opens nothing")
        XCTAssertEqual(AgentPlanLimits.settingsPane, "ext:com.prosper.ccpool|ccpool")
    }
}

// MARK: - #2011: groups by harness (design #2003 section 6); #1999's Codex card reads group("codex")

extension AgentIslandPlanLimitsTests {
    @MainActor private func runtime() -> CCPoolRuntime {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let defaults: UserDefaults = XCTestDefaults(suiteName: "prosper-plan-limits-\(UUID().uuidString)")!
        XCTAssertTrue(defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        return CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                             vaultURL: dir.appendingPathComponent("old"), defaults: defaults, probeBase: cfg.upstream,
                             logger: CCPoolCapturingLogger())
    }

    /// A Codex ChatGPT account (the pool's own add path makes a Claude one; the harness and kind are what #2005 sets).
    @MainActor private func addCodex(_ rt: CCPoolRuntime, _ label: String, headers: [String: String], t: Double) throws {
        let id = try rt.store.addAccount(label: label, token: "example-token-\(label)", secrets: rt.secrets)
        rt.store.mutate {
            $0.accounts[label]?.harness = CCPoolCodexHarness.id
            $0.accounts[label]?.kind = CCPoolCodexHarness.chatgptKind
        }
        rt.store.recordUsage(id: id, limits: CCPoolCodexHarness.parseLimits(headers, now: t).limits)
    }

    @MainActor func testTwoHarnessesGiveTwoGroupsWithTheirOwnDisplayAndCurrent() throws {
        let rt = runtime()
        let t = Date().timeIntervalSince1970
        let idA = try rt.store.addAccount(label: "alpha", token: "example-token-a", secrets: rt.secrets)
        rt.store.recordUsage(id: idA, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.3"]).limits)
        try addCodex(rt, "cx1", headers: ["x-codex-primary-used-percent": "40", "x-codex-primary-window-minutes": "300",
                                          "x-codex-secondary-used-percent": "20", "x-codex-secondary-window-minutes": "10080"], t: t)
        try addCodex(rt, "cx2", headers: ["x-codex-primary-used-percent": "10", "x-codex-primary-window-minutes": "20160"], t: t)
        rt.store.mutate {
            $0.currents = [ClaudeHarness.id: "alpha", CCPoolCodexHarness.id: "cx1"]
            $0.accounts["alpha"]?.reset = ["five_hour": Int(t) + 7200]
            $0.accounts["cx1"]?.reset = ["five_hour": Int(t) + 3600, "seven_day": Int(t) + 3 * 86400]
            $0.accounts["cx2"]?.reset = ["window_20160m": Int(t) + 86400]
        }
        let l = rt.planLimits(now: t)
        XCTAssertEqual(l.groups.map(\.harness), ["claude", "codex"])
        XCTAssertEqual(l.groups.map(\.title), ["Claude", "Codex"])
        XCTAssertEqual(l.accounts.map(\.label), ["alpha"], "the popover's accounts are the Claude group's only")
        XCTAssertEqual(l.accounts.map(\.isCurrent), [true])
        XCTAssertEqual(l.accounts.map(\.harness), ["claude"])
        XCTAssertEqual(l.pool, l.group("claude")?.pool)
        let codex = try XCTUnwrap(l.group("codex"))
        XCTAssertEqual(codex.accounts.map(\.label), ["cx1", "cx2"], "most urgent first")
        XCTAssertEqual(codex.accounts.map(\.isCurrent), [true, false], "Codex's own current")
        XCTAssertEqual(codex.accounts.map(\.harness), ["codex", "codex"])
        XCTAssertEqual(codex.accounts.first?.limits.map(\.name), ["5h", "week"])
        XCTAssertEqual(codex.accounts.last?.limits.map(\.name), ["14d"], "Codex's own word for a two-week window")
        let pool = try XCTUnwrap(codex.pool)
        XCTAssertTrue(pool.hasPrefix("5h 60%") && pool.contains("week 80%") && pool.contains("14d 90%"), pool)
        XCTAssertFalse(pool.contains("window_"), pool)
        XCTAssertTrue(l.pool?.hasPrefix("5h 70%") == true, "a Codex share never counts in the Claude pool: \(l.pool ?? "nil")")
    }

    @MainActor func testCodexOnlyPoolGivesNoClaudeGroupAndNoClaudeLine() throws {
        let rt = runtime()
        let t = Date().timeIntervalSince1970
        try addCodex(rt, "cx", headers: ["x-codex-primary-used-percent": "40", "x-codex-primary-window-minutes": "300"], t: t)
        rt.store.mutate { $0.currents[CCPoolCodexHarness.id] = "cx" }
        let l = rt.planLimits(now: t)
        XCTAssertEqual(l.groups.map(\.harness), ["codex"])
        XCTAssertTrue(l.group("claude") == nil)
        XCTAssertTrue(l.accounts.isEmpty && l.pool == nil, "the popover's Claude part is empty")
        XCTAssertTrue(rt.planUsage(now: t) == nil, "the Claude line is empty")
        XCTAssertTrue(rt.planUsage(now: t, harness: "claude") == nil)
        let u = try XCTUnwrap(rt.planUsage(now: t, harness: "codex"))
        XCTAssertEqual(u.session, 0.4)
        XCTAssertEqual(u.plan, "Codex")
        XCTAssertTrue(u.help().hasPrefix("Codex plan usage"))
    }

    @MainActor func testNoCodexAccountGivesNoCodexGroup() throws {
        let rt = runtime()
        let t = Date().timeIntervalSince1970
        let id = try rt.store.addAccount(label: "alpha", token: "example-token-a", secrets: rt.secrets)
        rt.store.recordUsage(id: id, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.3"]).limits)
        rt.store.mutate { $0.current = "alpha" }
        let l = rt.planLimits(now: t)
        XCTAssertEqual(l.groups.map(\.harness), ["claude"])
        XCTAssertTrue(l.group("codex") == nil)
        XCTAssertTrue(rt.planUsage(now: t, harness: "codex") == nil, "no Codex current: no Codex line")
        let u = try XCTUnwrap(rt.planUsage(now: t, harness: "claude"))
        XCTAssertEqual(u.session, 0.3)
        XCTAssertEqual(u.plan, "Claude")
        XCTAssertTrue(u.help().hasPrefix("Claude plan usage"))
    }

    /// A current that names an account of another harness is not that harness's line.
    @MainActor func testPlanUsageNeedsTheCurrentToServeThatHarness() throws {
        let rt = runtime()
        let t = Date().timeIntervalSince1970
        try addCodex(rt, "cx", headers: ["x-codex-primary-used-percent": "40", "x-codex-primary-window-minutes": "300"], t: t)
        rt.store.mutate { $0.current = "cx" }
        XCTAssertTrue(rt.planUsage(now: t) == nil, "a Codex account is never the Claude line")
    }

    func testLegacyCurrentDecodesAsClaudes() throws {
        let json = #"{"current":"alpha","order":["alpha","cx"],"accounts":{"alpha":{"id":"a1"},"cx":{"id":"c1","harness":"codex"}}}"#
        var st = try JSONDecoder().decode(CCPoolState.self, from: Data(json.utf8))
        XCTAssertEqual(st.currents, ["claude": "alpha"], "the single legacy value is Claude's")
        st.remember("cx")
        XCTAssertEqual(st.currents, ["claude": "alpha", "codex": "cx"], "Codex's current is its own")
    }

    func testPaceReachesEveryGroupByLabel() throws {
        let a = account("alpha", util: ["five_hour": 0.75], reset: ["five_hour": Int(now) + 7200])
        let cx = AgentPlanLimits.Account(label: "cx", isCurrent: true, util: ["five_hour": 0.75], at: now - 60,
                                         reset: ["five_hour": Int(now) + 7200], cooldown: [:], claims: [("five_hour", "5h")],
                                         now: now, harness: "codex")
        let l = AgentPlanLimits(groups: [.init(harness: "claude", title: "Claude", pool: nil, accounts: [a]),
                                         .init(harness: "codex", title: "Codex", pool: nil, accounts: [cx])])
            .withPace(["cx": ["five_hour": pace(rising)]], now: now)
        XCTAssertEqual(l.group("codex")?.accounts.first?.limits.first?.runsOut, Int(now) + 3000, "the Codex row's own samples")
        XCTAssertTrue(l.accounts.first?.limits.first?.runsOut == nil, "alpha has no samples")
    }

    @MainActor func testTheLineFollowsTheFocusedSessionsHarness() throws {
        let saved = Preferences.defaults.object(forKey: "agentIslandShowPlanUsage")
        defer { if let v = saved { Preferences.defaults.set(v, forKey: "agentIslandShowPlanUsage") } else { Preferences.defaults.removeObject(forKey: "agentIslandShowPlanUsage") } }
        Preferences.agentIslandShowPlanUsage = true
        let c = controller({ nil }, limits: { nil })
        var asked: [String] = []
        c.planUsage = { _, h in asked.append(h); return nil }
        let store = try XCTUnwrap(c.store)
        let codexKey = AgentSessionKey(dir: "/Users/example/d", name: "api-qa")
        var codexRow = AgentSession(key: codexKey, alias: "", activity: 0, state: .idle, agents: 0)
        codexRow.agent = "codex"
        store.sessions.append(codexRow)
        c.readPlanUsage()
        store.focusKey = store.sessions.first?.key
        c.readPlanUsage()
        store.focusKey = codexKey
        c.readPlanUsage()
        store.focusKey = AgentSessionKey(dir: "/Users/example/d", name: "gone")
        c.readPlanUsage()
        XCTAssertEqual(asked, ["claude", "claude", "codex", "claude", "claude"], "no focus, a Claude row, a Codex row (then the Claude fallback), an unknown row")
    }

    @MainActor func testACodexRowWithoutACodexLineFallsBackToClaudes() throws {
        let saved = Preferences.defaults.object(forKey: "agentIslandShowPlanUsage")
        defer { if let v = saved { Preferences.defaults.set(v, forKey: "agentIslandShowPlanUsage") } else { Preferences.defaults.removeObject(forKey: "agentIslandShowPlanUsage") } }
        Preferences.agentIslandShowPlanUsage = true
        let c = controller({ nil }, limits: { nil })
        let store = try XCTUnwrap(c.store)
        let codexKey = AgentSessionKey(dir: "/Users/example/d", name: "api-qa")
        var codexRow = AgentSession(key: codexKey, alias: "", activity: 0, state: .idle, agents: 0)
        codexRow.agent = "codex"
        store.sessions.append(codexRow)
        store.focusKey = codexKey
        let t = Date().timeIntervalSince1970
        let claude = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.4], at: t, reset: [:], now: t))
        var codex: AgentPlanUsage?
        var asked: [String] = []
        c.planUsage = { _, h in asked.append(h); return h == "codex" ? codex : claude }
        c.readPlanUsage()
        XCTAssertEqual(store.planUsage, claude, "no Codex current: Claude's line stays")
        XCTAssertEqual(asked, ["codex", "claude"])
        codex = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.9], at: t, reset: [:], now: t))
        codex?.plan = "Codex"
        asked = []
        c.readPlanUsage()
        XCTAssertEqual(store.planUsage, codex, "a Codex value wins")
        XCTAssertEqual(asked, ["codex"], "no Claude call")
    }
}
