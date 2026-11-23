import SwiftUI
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
        XCTAssertEqual(AgentPlanLimits.resetText(first, now: now, timeZone: utc), "resets in 2 h 14 min (Fri 10:14)")
        XCTAssertEqual(AgentPlanLimits.spoken(a, now: now, timeZone: utc),
                       "alpha, current, 5 hour 15 percent, resets in 2 hours 14 minutes, Friday 10:14; "
                       + "week 99 percent, resets in 3 days, Monday 08:00, updated 3 min ago")
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
            $0.accounts["beta"]?.reset = ["five_hour": Int(t) + 3600]
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
        XCTAssertTrue(l.pool?.hasPrefix("5h 85%") == true, "alpha 10% free + beta 75% free; got \(l.pool ?? "nil")")
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
        c.planUsage = { _ in usage() }
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
        let tree = AXTreeSupport.tree(view, CGSize(width: 320, height: 400)) { t in spoken.allSatisfy { s in t.contains { $0.reads(s) } } }
        for s in spoken { XCTAssertTrue(tree.contains { $0.reads(s) }, "one element per account: \(s)") }
        XCTAssertTrue(tree.contains { $0.reads("Free across all accounts: 5h 62% \u{00B7} week 18%") }, "the pool on top")
        let buttons = tree.filter { $0.role == "AXButton" }
        XCTAssertEqual(buttons.count, 1, "read only: the settings link is the one control; got \(buttons.map(\.names))")
        XCTAssertTrue(buttons.first?.reads(AgentPlanLimits.settingsLink) == true)
        XCTAssertEqual(opened, 0, "drawing opens nothing")
        XCTAssertEqual(AgentPlanLimits.settingsPane, "ext:com.prosper.ccpool|ccpool")
    }
}
