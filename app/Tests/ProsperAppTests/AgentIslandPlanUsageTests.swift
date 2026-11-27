import XCTest
@testable import ProsperApp

/// #1537 (OQ-95 part 3): the Claude plan usage (session and weekly limit) on the open island, from the account
/// pool's in-memory usage sample. Fakes only: the controller's `planUsage` seam is a literal, no panel is built or
/// ordered (`showsPanel = false`), no monitor is installed, no dch runs; the runtime row builds its own pool on a
/// tempDir() with memory secrets and binds and dials nothing.
final class AgentIslandPlanUsageTests: XCTestCase {
    private let now: Double = 1_800_000_000   // Fri 08:00 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    @MainActor private func controller(_ usage: AgentPlanUsage?) -> AgentIslandController {
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
        c.planUsage = { _, _ in usage }
        let store = AgentIslandStore(geometry: notched, sort: .name, sidekickPattern: "")
        store.sessions = [AgentSession(key: AgentSessionKey(dir: "/Users/example/d", name: "api"), alias: "", activity: 0,
                                       state: .idle, agents: 0)]
        c.store = store
        return c
    }

    // MARK: - No data: nothing drawn

    func testNoSampleOrNoLimitClaimMeansNothingDrawn() {
        XCTAssertTrue(AgentPlanUsage(util: [:], at: now, reset: [:], now: now) == nil, "no sample: no line")
        XCTAssertTrue(AgentPlanUsage(util: ["seven_day_opus": 0.5], at: now, reset: [:], now: now) == nil,
                      "a model-only limit is neither the session nor the week")
    }

    @MainActor func testNoUsageKeepsTheIslandAsBefore() throws {
        let c = controller(nil)
        c.setExpanded(true)
        let store = try XCTUnwrap(c.store)
        XCTAssertTrue(store.expanded)
        XCTAssertTrue(store.planUsage == nil)
        XCTAssertFalse(store.showsTabRow, "no tabs and no usage: no tab row")
        XCTAssertEqual(store.size, notched.expandedSize(rows: store.rowHeights, cards: store.cardsHeight, tabs: false))
    }

    // MARK: - Values and resets are formatted

    func testValuesAndResetsAreFormatted() throws {
        let u = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.416, "seven_day": 0.1, "seven_day_opus": 0.9], at: now - 60,
                                             reset: ["five_hour": 1_800_007_200, "seven_day": 1_800_259_200], now: now))
        XCTAssertEqual(u.text, "5h 42% \u{00B7} week 10%")
        XCTAssertEqual(u.help(timeZone: utc), "Claude plan usage (account pool, current account)\n"
                       + "Session limit: 42% used, resets Fri 10:00\nWeekly limit: 10% used, resets Mon 08:00")
    }

    func testOneLimitAloneAndNoResetAreFormatted() throws {
        let u = try XCTUnwrap(AgentPlanUsage(util: ["seven_day": 1.0], at: now - 60, reset: [:], now: now))
        XCTAssertEqual(u.text, "week 100%")
        XCTAssertEqual(u.help(timeZone: utc), "Claude plan usage (account pool, current account)\nWeekly limit: 100% used")
    }

    // MARK: - Stale is dropped

    func testAValuePastItsResetIsDropped() throws {
        let u = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.9, "seven_day": 0.3], at: now - 60,
                                             reset: ["five_hour": Int(now), "seven_day": 1_800_259_200], now: now))
        XCTAssertTrue(u.session == nil, "the session window rolled over at its reset (now == reset): dropped")
        XCTAssertEqual(u.text, "week 30%")
        XCTAssertTrue(AgentPlanUsage(util: ["five_hour": 0.9], at: now - 60, reset: ["five_hour": Int(now) - 1], now: now) == nil,
                      "the only value stale: nothing drawn")
    }

    func testWithoutAResetAValueOlderThanItsWindowIsDropped() throws {
        let u = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.9, "seven_day": 0.3], at: now - 5 * 3600, reset: [:], now: now))
        XCTAssertTrue(u.session == nil, "5 h old: the session window is over")
        XCTAssertEqual(u.week, 0.3, "a week window is still open")
        let fresh = try XCTUnwrap(AgentPlanUsage(util: ["five_hour": 0.9], at: now - 5 * 3600 + 1, reset: [:], now: now))
        XCTAssertEqual(fresh.session, 0.9, "one second inside the window: kept")
        XCTAssertTrue(AgentPlanUsage(util: ["seven_day": 0.3], at: now - 7 * 86400, reset: [:], now: now) == nil)
    }

    func testOutOfRangeValuesAreDropped() {
        for bad in [-0.01, 100.5, .nan, .infinity] {
            XCTAssertTrue(AgentPlanUsage(util: ["five_hour": bad], at: now, reset: [:], now: now) == nil, "\(bad)")
        }
    }

    // MARK: - #1552: the Show plan usage setting (Preferences.defaults is a scratch suite under XCTest)

    private static let key = "agentIslandShowPlanUsage"

    @MainActor func testShowPlanUsageIsOnByDefault() {
        let saved = Preferences.defaults.object(forKey: Self.key)
        defer { if let v = saved { Preferences.defaults.set(v, forKey: Self.key) } else { Preferences.defaults.removeObject(forKey: Self.key) } }
        Preferences.defaults.removeObject(forKey: Self.key)
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard, "a private defaults store")
        XCTAssertTrue(Preferences.agentIslandShowPlanUsage, "unset reads on")
        Preferences.agentIslandShowPlanUsage = false
        XCTAssertFalse(Preferences.agentIslandShowPlanUsage)
    }

    @MainActor func testOffHidesTheLineEvenWithDataAndDoesNotKeepTheTabRow() throws {
        let saved = Preferences.defaults.object(forKey: Self.key)
        defer { if let v = saved { Preferences.defaults.set(v, forKey: Self.key) } else { Preferences.defaults.removeObject(forKey: Self.key) } }
        let t = Date().timeIntervalSince1970
        let usage = AgentPlanUsage(util: ["five_hour": 0.42], at: t, reset: [:], now: t)
        Preferences.agentIslandShowPlanUsage = false
        let c = controller(usage)
        let store = try XCTUnwrap(c.store)
        c.setExpanded(true)
        XCTAssertTrue(store.planUsage == nil, "off: not drawn with data present")
        XCTAssertFalse(store.showsTabRow, "off: the row is not kept for the usage line alone")
        Preferences.agentIslandShowPlanUsage = true
        let on = controller(usage)
        on.setExpanded(true)
        XCTAssertEqual(on.store?.planUsage, usage, "on: drawn")
    }

    @MainActor func testOnWithNoDataHidesTheLine() throws {
        let saved = Preferences.defaults.object(forKey: Self.key)
        defer { if let v = saved { Preferences.defaults.set(v, forKey: Self.key) } else { Preferences.defaults.removeObject(forKey: Self.key) } }
        Preferences.agentIslandShowPlanUsage = true
        let c = controller(nil)
        let store = try XCTUnwrap(c.store)
        c.setExpanded(true)
        XCTAssertTrue(store.planUsage == nil)
        XCTAssertFalse(store.showsTabRow)
    }

    func testSettingsRowTextAndPlacement() throws {
        XCTAssertEqual(AgentIslandLookSection.usageLabel, "Show plan usage")
        XCTAssertEqual(AgentIslandLookSection.usageSubtitle, "Your Claude plan usage, from the account pool, when it has a recent figure.")
    }

    // MARK: - The island

    @MainActor func testOpeningTheIslandShowsTheUsageRowAndGrowsByIt() throws {
        let usage = AgentPlanUsage(util: ["five_hour": 0.42], at: Date().timeIntervalSince1970, reset: [:],
                                   now: Date().timeIntervalSince1970)
        let c = controller(usage)
        let store = try XCTUnwrap(c.store)
        XCTAssertTrue(store.planUsage == nil, "collapsed: not read yet")
        c.setExpanded(true)
        XCTAssertEqual(store.planUsage, usage)
        XCTAssertFalse(store.showsTabs, "one session, no history: no tabs")
        XCTAssertTrue(store.showsTabRow, "the usage alone brings the row up")
        XCTAssertEqual(store.size, notched.expandedSize(rows: store.rowHeights, cards: store.cardsHeight, tabs: true),
                       "the panel is sized with the row")
    }

    // MARK: - The pool's accessor

    @MainActor func testRuntimeReadsTheCurrentAccountsSampleAndResets() throws {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let defaults: UserDefaults = XCTestDefaults(suiteName: "prosper-plan-usage-\(UUID().uuidString)")!
        XCTAssertTrue(defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: defaults, probeBase: cfg.upstream,
                               logger: CCPoolCapturingLogger())
        let t = Date().timeIntervalSince1970
        XCTAssertTrue(rt.planUsage(now: t) == nil, "no account")
        let idA = try rt.store.addAccount(label: "alpha", token: "example-token-a", secrets: rt.secrets)
        let idB = try rt.store.addAccount(label: "beta", token: "example-token-b", secrets: rt.secrets)
        rt.store.mutate { $0.current = "beta"; $0.accounts["beta"]?.reset = ["five_hour": Int(t) + 3600] }
        rt.store.recordUsage(id: idA, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.9"]).limits)
        XCTAssertTrue(rt.planUsage(now: t) == nil, "only another account has a sample: not this plan's figure")
        rt.store.recordUsage(id: idB, limits: CCPoolCore.parseLimits(["anthropic-ratelimit-unified-5h-utilization": "0.25",
                                                                      "anthropic-ratelimit-unified-7d-utilization": "0.5"]).limits)
        let u = try XCTUnwrap(rt.planUsage(now: t))
        XCTAssertEqual(u.session, 0.25)
        XCTAssertEqual(u.sessionReset, Int(t) + 3600, "the current account's reset stamp")
        XCTAssertEqual(u.week, 0.5)
        XCTAssertTrue(u.weekReset == nil)
    }
}
