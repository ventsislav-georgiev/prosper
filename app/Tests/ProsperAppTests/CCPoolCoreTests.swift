import XCTest
@testable import ProsperApp

/// #871: ports of the Python ccpool unit checks (test_ccpool.py, ccpool.py selection/exhaustion
/// rules) against the pure core. Clock injected; dummy tokens only.
final class CCPoolCoreTests: XCTestCase {
    let now = 1_800_000_000.0

    private func pool(_ labels: [String], current: String? = nil) -> CCPoolState {
        CCPoolState(current: current, order: labels,
                    accounts: Dictionary(uniqueKeysWithValues: labels.map { ($0, CCPoolState.Account(id: "id-\($0)")) }))
    }

    // B4
    func testClaimsPerModelIncludingFableAndUnknown() {
        XCTAssertEqual(CCPoolCore.claims(for: "claude-opus-5"), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(CCPoolCore.claims(for: "claude-fable-5"), ["five_hour", "seven_day", "seven_day_overage_included"])
        XCTAssertEqual(CCPoolCore.claims(for: "claude-sonnet-4-5"), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(CCPoolCore.claims(for: "claude-haiku-4-5-20251001"), ["five_hour", "seven_day"])
        XCTAssertEqual(CCPoolCore.claims(for: "mystery-model"), CCPoolCore.mostRestrictive)
        XCTAssertEqual(CCPoolCore.claims(for: nil), CCPoolCore.mostRestrictive)
        XCTAssertTrue(CCPoolCore.isKnownModel("claude-fable-5"))
        XCTAssertFalse(CCPoolCore.isKnownModel("mystery-model"))
    }

    // B4
    func testEligibilityPerModel() {
        var st = pool(["a"])
        st.accounts["a"]?.cooldown = ["seven_day_opus": Int(now) + 600]
        XCTAssertFalse(CCPoolCore.eligible(st.accounts["a"], model: "claude-opus-5", now: now))
        XCTAssertTrue(CCPoolCore.eligible(st.accounts["a"], model: "claude-sonnet-4-5", now: now))
        XCTAssertTrue(CCPoolCore.eligible(st.accounts["a"], model: "claude-haiku-4-5", now: now))
        XCTAssertFalse(CCPoolCore.eligible(st.accounts["a"], model: nil, now: now), "unknown model is held back by every claim")
        XCTAssertTrue(CCPoolCore.eligible(st.accounts["a"], model: "claude-opus-5", now: now + 600), "a cooldown ending now is over")
        st.accounts["a"]?.cooldown = ["five_hour": Int(now) + 1]
        XCTAssertFalse(CCPoolCore.eligible(st.accounts["a"], model: "claude-haiku-4-5", now: now))
    }

    // B5 (test_ccpool.py:164 stickiness)
    func testPickStaysOnCurrentWhileEligible() {
        var st = pool(["a", "b", "c"], current: "c")
        st.accounts["a"]?.reset = ["five_hour": Int(now) + 60]
        st.accounts["b"]?.reset = ["five_hour": Int(now) + 120]
        XCTAssertEqual(CCPoolCore.pick(st, model: "claude-opus-5", exclude: [], now: now), "c")
        XCTAssertEqual(CCPoolCore.pick(st, model: "claude-opus-5", exclude: ["c"], now: now), "a")
        st.accounts["c"]?.cooldown = ["five_hour": Int(now) + 60]
        XCTAssertEqual(CCPoolCore.pick(st, model: "claude-opus-5", exclude: [], now: now), "a")
    }

    // B5 (ccpool.py:196-203; no Python test existed)
    func testPickSoonestFiveHourThenUnseenLastThenOrder() {
        var st = pool(["a", "b", "c", "d"])
        st.accounts["c"]?.reset = ["five_hour": Int(now) + 300]
        st.accounts["d"]?.reset = ["five_hour": Int(now) + 100]
        XCTAssertEqual(CCPoolCore.pick(st, model: nil, exclude: [], now: now), "d", "soonest rollover first")
        XCTAssertEqual(CCPoolCore.pick(st, model: nil, exclude: ["d"], now: now), "c")
        XCTAssertEqual(CCPoolCore.pick(st, model: nil, exclude: ["d", "c"], now: now), "a", "unseen windows last, ties by order")
        st.accounts["d"]?.reset = ["five_hour": Int(now) - 1]
        XCTAssertEqual(CCPoolCore.pick(st, model: nil, exclude: [], now: now), "c", "a past reset counts as unseen")
        XCTAssertNil(CCPoolCore.pick(st, model: nil, exclude: ["a", "b", "c", "d"], now: now))
        XCTAssertNil(CCPoolCore.pick(pool([]), model: nil, exclude: [], now: now))
        st.current = "gone"
        XCTAssertEqual(CCPoolCore.pick(st, model: nil, exclude: [], now: now), "c", "a current label no longer listed is ignored")
    }

    // B6
    func testUnreachableKeys() {
        var st = pool(["a", "b"])
        st.accounts["a"]?.cooldown = ["five_hour": 1, "seven_day_overage_included": 1]
        st.accounts["b"]?.cooldown = ["overage": 1, "seven_day_fable": 1]
        XCTAssertEqual(CCPoolCore.unreachableKeys(st), ["overage", "seven_day_fable"])
    }

    /// Header names and values as a real 200 carries them, including overage-status "rejected" on
    /// a healthy account (the trap behind two wrong Python drafts).
    private let realHeaders = [
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "anthropic-ratelimit-unified-5h-utilization": "0.10",
        "anthropic-ratelimit-unified-5h-reset": "1800003600",
        "Anthropic-Ratelimit-Unified-7d-Status": "allowed",
        "anthropic-ratelimit-unified-7d-utilization": "0.12",
        "anthropic-ratelimit-unified-7d-overage-included-status": "allowed",
        "anthropic-ratelimit-unified-7d-overage-included-utilization": "0.34",
        "anthropic-ratelimit-unified-overage-status": "rejected",
        "anthropic-ratelimit-unified-overage-disabled-reason": "org_level_disabled",
        "anthropic-ratelimit-unified-fallback-status": "rejected",
        "anthropic-ratelimit-unified-representative-claim": "five_hour",
        "anthropic-ratelimit-unified-status": "allowed",
        "content-type": "application/json",
    ]

    // B7
    func testHeaderParseSkipsOverageAndFallback() {
        let (limits, unknown) = CCPoolCore.parseLimits(realHeaders)
        XCTAssertEqual(Set(limits.keys), ["five_hour", "seven_day", "seven_day_overage_included"])
        XCTAssertEqual(limits["five_hour"], CCPoolLimit(status: "allowed", utilization: "0.10", reset: "1800003600"))
        XCTAssertEqual(limits["seven_day"]?.status, "allowed", "header names are case-insensitive")
        XCTAssertEqual(limits["seven_day_overage_included"]?.utilization, "0.34")
        XCTAssertEqual(unknown, [])
        XCTAssertEqual(CCPoolCore.exhaustedClaims(limits, now: now), [:], "overage-status rejected is not exhaustion")
    }

    // B7: an unknown abbreviation is reported for a log line and never benches.
    func testUnknownAbbreviationIsIgnoredAndNeverBenches() {
        var h = realHeaders
        h["anthropic-ratelimit-unified-1d-status"] = "rejected"
        h["anthropic-ratelimit-unified-1d-utilization"] = "1.0"
        let (limits, unknown) = CCPoolCore.parseLimits(h)
        XCTAssertEqual(unknown, ["1d"])
        XCTAssertEqual(Set(limits.keys), ["five_hour", "seven_day", "seven_day_overage_included"])
        XCTAssertEqual(CCPoolCore.exhaustedClaims(limits, now: now), [:])
        // Alone, so no known row can mask it (header order is a dictionary's).
        let (alone, aloneUnknown) = CCPoolCore.parseLimits([
            "anthropic-ratelimit-unified-1d-status": "rejected",
            "anthropic-ratelimit-unified-1d-utilization": "1.0",
            "anthropic-ratelimit-unified-1d-reset": "1800003600",
        ])
        XCTAssertEqual(aloneUnknown, ["1d"])
        XCTAssertEqual(alone, [:], "an unknown row never becomes a claim")
    }

    // B8
    func testExhaustedRules() {
        let r = "1800003600"
        let limits = [
            "five_hour": CCPoolLimit(status: "rejected", utilization: "0.42", reset: r),
            "seven_day": CCPoolLimit(status: "allowed", utilization: "1.0", reset: r),
            "seven_day_opus": CCPoolLimit(status: "allowed_warning", utilization: "0.999", reset: r),
            "seven_day_sonnet": CCPoolLimit(status: "allowed", utilization: "not-a-number", reset: r),
        ]
        XCTAssertEqual(CCPoolCore.exhaustedClaims(limits, now: now), ["five_hour": 1_800_003_600, "seven_day": 1_800_003_600])
        XCTAssertEqual(Set(CCPoolCore.exhaustedClaims(limits, now: now, threshold: 0.98).keys),
                       ["five_hour", "seven_day", "seven_day_opus"], "the threshold is a hidden default")
    }

    // B8: spent with no usable reset -> the 900 s UNCONFIRMED bench, never longer.
    func testUnconfirmedBenchWhenResetMissingOrUnusable() {
        for reset in [nil, "", "soon", "inf", "nan", "1e300"] as [String?] {
            let limits = ["five_hour": CCPoolLimit(status: "rejected", utilization: nil, reset: reset)]
            XCTAssertEqual(CCPoolCore.exhaustedClaims(limits, now: now), ["five_hour": Int(now) + 900], "\(reset ?? "nil")")
        }
        XCTAssertEqual(CCPoolCore.unconfirmedBench, 900)
    }

    // B3
    func testBenchCappedAtEightDaysAndNeverShortened() {
        var st = pool(["a"])
        st.bench("a", claim: "seven_day", until: Int(now) + 30 * 86400, now: now)
        XCTAssertEqual(st.accounts["a"]?.cooldown["seven_day"], Int(now) + 8 * 86400)
        st.bench("a", claim: "seven_day", until: Int(now) + 60, now: now)
        XCTAssertEqual(st.accounts["a"]?.cooldown["seven_day"], Int(now) + 8 * 86400, "a shorter bench never shortens")
        XCTAssertFalse(st.bench("ghost", claim: "five_hour", until: Int(now) + 60, now: now))
        XCTAssertNil(st.accounts["ghost"])
    }

    // B22 (test_ccpool.py hold/clear checks)
    func testHoldAndClear() {
        var st = pool(["h1", "h2"])
        XCTAssertFalse(st.hold("nope", hours: 24, now: now), "holding a name that does not exist is an error")
        XCTAssertTrue(st.hold("h1", hours: 24, now: now))
        XCTAssertEqual(st.accounts["h1"]?.cooldown, ["five_hour": Int(now) + 86400])
        XCTAssertEqual(CCPoolCore.pick(st, model: "claude-opus-5", exclude: [], now: now), "h2", "the held account is skipped")
        st.clear("h1")
        XCTAssertEqual(st.accounts["h1"]?.cooldown, [:], "clear releases it")
        st.hold("h1", hours: 1, now: now)
        st.hold("h2", hours: 1000, now: now)
        XCTAssertEqual(st.accounts["h2"]?.cooldown["five_hour"], Int(now) + 8 * 86400, "a hold is a bench: capped too")
        st.accounts["h1"]?.cooldown["seven_day"] = Int(now) + 5
        st.clear("h1", claim: "five_hour")
        XCTAssertEqual(st.accounts["h1"]?.cooldown, ["seven_day": Int(now) + 5], "clear one claim leaves the rest")
        st.clear(nil)
        XCTAssertTrue(st.accounts.values.allSatisfy { $0.cooldown.isEmpty }, "clear all releases every account")
    }

    // QA #734 INFO-8: hold refuses inf, NaN, zero and negatives; a huge finite value is capped.
    func testHoldRefusesNonFiniteAndCapsHuge() {
        var st = pool(["h"])
        for bad in [Double.infinity, -Double.infinity, Double.nan, 0, -1] {
            XCTAssertFalse(st.hold("h", hours: bad, now: now), "\(bad)")
            XCTAssertEqual(st.accounts["h"]?.cooldown, [:], "\(bad): nothing benched")
            XCTAssertNil(st.accounts["h"]?.held)
        }
        XCTAssertTrue(st.hold("h", hours: 1e300, now: now))
        XCTAssertEqual(st.accounts["h"]?.cooldown["five_hour"], Int(now) + CCPoolCore.maxBench, "capped before Int()")
        XCTAssertEqual(st.accounts["h"]?.held, Int(now) + CCPoolCore.maxBench)
    }

    private func utilLimits(_ values: [String: String]) -> [String: CCPoolLimit] {
        CCPoolCore.parseLimits(Dictionary(uniqueKeysWithValues: values.map {
            ("anthropic-ratelimit-unified-\($0.key)-utilization", $0.value) })).limits
    }

    // A2 list: a utilisation header outside 0...100 is dropped (the pane turns shares into Int percents).
    func testUtilisationOutOfRangeIsDropped() {
        let u = CCPoolCore.utils(utilLimits(["5h": "nan", "7d": "inf", "7d-opus": "1e300", "7d-sonnet": "-0.5", "7d-overage-included": " 0.4 "]))
        XCTAssertEqual(Array(u.values), [0.4], "\(u)")
    }

    // The same headers end in the pane's texts without a trap.
    func testUtilisationOutOfRangeNoTrapInPane() {
        let limits = utilLimits(["5h": "nan", "7d": "1e300", "7d-opus": "-1e300", "7d-overage-included": "0.4"])
        let sample = CCPoolUsageSample(util: CCPoolCore.utils(limits), at: now)
        XCTAssertTrue(CCPoolPaneModel.usageText(sample, now: now).contains("40%"))
        let cells = CCPoolCore.poolCells([.init(util: CCPoolCore.utils(limits), reset: ["seven_day_overage_included": Int(now) + 3600],
                                                spent: [:])], now: now)
        XCTAssertEqual(cells.map(\.free), [0.6])
    }

    // B22 (test_ccpool.py:239-257): a hold on Fable leaves Opus usable.
    func testHoldOnFableLeavesOpusUsable() {
        var st = pool(["s-ok"])
        st.bench("s-ok", claim: "seven_day_overage_included", until: Int(now) + 4 * 86400, now: now)
        XCTAssertNil(CCPoolCore.pick(st, model: "claude-fable-5", exclude: [], now: now))
        XCTAssertEqual(CCPoolCore.pick(st, model: "claude-opus-5", exclude: [], now: now), "s-ok")
    }

    // B2, B15
    func testRecordResetsRememberAndNextReset() {
        var st = pool(["a", "b"])
        let limits = ["five_hour": CCPoolLimit(status: "allowed", utilization: "0.4", reset: String(Int(now) + 100)),
                      "seven_day": CCPoolLimit(status: "allowed", utilization: "0.1", reset: String(Int(now) - 5))]
        st.recordResets("a", limits: limits, now: now)
        XCTAssertEqual(st.accounts["a"]?.reset, ["five_hour": Int(now) + 100], "past rollovers are not recorded")
        st.remember("b")
        XCTAssertEqual(st.current, "b")
        st.remember("ghost")
        XCTAssertEqual(st.current, "b")
        st.accounts["a"]?.cooldown = ["seven_day_opus": Int(now) + 50, "seven_day_sonnet": Int(now) + 10]
        st.accounts["b"]?.cooldown = ["five_hour": Int(now) + 70, "seven_day": Int(now) - 1]
        XCTAssertEqual(CCPoolCore.nextReset(st, model: "claude-opus-5", now: now), Int(now) + 50)
        XCTAssertEqual(CCPoolCore.nextReset(st, model: nil, now: now), Int(now) + 10)
        XCTAssertNil(CCPoolCore.nextReset(st, model: "claude-haiku-4-5", now: now + 100))
    }

    // B21 headroom maths for the All row (test_ccpool.py status/headroom checks).
    func testPoolHeadroom() {
        let soon = Int(now) + 3600
        let full = CCPoolCore.LiveAccount(util: ["five_hour": 0.995, "seven_day": 0.12, "seven_day_overage_included": 0.34],
                                          reset: ["five_hour": soon, "seven_day": soon + 86400],
                                          spent: ["five_hour": soon])
        var ok = CCPoolCore.LiveAccount(util: ["five_hour": 0.10, "seven_day": 0.12, "seven_day_overage_included": 0.34],
                                        reset: ["five_hour": soon, "seven_day": soon + 86400], spent: [:])
        var cells = CCPoolCore.poolCells([full, ok], now: now)
        XCTAssertEqual(cells.map(\.claim), ["five_hour", "seven_day", "seven_day_overage_included"])
        XCTAssertEqual(cells[0].free, 0.9, accuracy: 1e-9, "the benched account contributes nothing")
        XCTAssertEqual(cells[0].growsAt, soon, "the next reset that grows headroom")
        // A hand hold on five_hour: the account stops counting toward pool headroom.
        ok.spent = ["five_hour": Int(now) + 86400]
        cells = CCPoolCore.poolCells([full, ok], now: now)
        XCTAssertEqual(cells[0].free, 0, accuracy: 1e-9)
        // A Fable hold: its 5h still counts, its Fable does not.
        ok.spent = ["seven_day_overage_included": Int(now) + 4 * 86400]
        cells = CCPoolCore.poolCells([full, ok], now: now)
        XCTAssertEqual(cells[0].free, 0.9, accuracy: 1e-9)
        XCTAssertEqual(cells[2].free, 0, accuracy: 1e-9)
        XCTAssertTrue(CCPoolCore.blocked(["seven_day": Int(now) + 1], claim: "seven_day_opus", at: now), "shared claims block every model")
        XCTAssertFalse(CCPoolCore.blocked(["seven_day_overage_included": Int(now) + 1], claim: "seven_day_opus", at: now))
    }

    // B2: the Python state shape decodes (no order, no id), order is repaired.
    func testStateDecodesPythonShapeAndRepairsOrder() throws {
        let json = #"{"current":"b","accounts":{"b":{"cooldown":{"five_hour":5}},"a":{"reset":{"seven_day":9}}}}"#
        let st = try JSONDecoder().decode(CCPoolState.self, from: Data(json.utf8))
        XCTAssertEqual(st.current, "b")
        XCTAssertEqual(st.order, ["a", "b"])
        XCTAssertEqual(st.accounts["b"]?.cooldown, ["five_hour": 5])
        XCTAssertEqual(st.accounts["a"]?.reset, ["seven_day": 9])
        let withOrder = #"{"order":["b","x","b"],"accounts":{"b":{"id":"u1"},"a":{"id":"u2"}}}"#
        XCTAssertEqual(try JSONDecoder().decode(CCPoolState.self, from: Data(withOrder.utf8)).order, ["b", "a"])
    }

    // B1/B2: the store writes 0600 state that never holds a token; add/remove go through the secrets seam.
    func testStoreAddRemovePersistsWithoutToken() throws {
        let dir = tempDir()
        let secrets = CCPoolMemorySecrets()
        let clock: @Sendable () -> Double = { 1_800_000_000 }
        let store = CCPoolStore(directory: dir.appendingPathComponent("ccpool"), clock: clock)
        try store.addAccount(label: "alpha", token: "tok-alpha\n", secrets: secrets)
        try store.addAccount(label: "beta", token: "tok-beta", secrets: secrets)
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-x", secrets: secrets)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .duplicateLabel)
        }
        XCTAssertThrowsError(try store.addAccount(label: "gamma", token: "  ", secrets: secrets)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .emptyToken)
        }
        XCTAssertEqual(secrets.count, 2, "nothing stored on a refused add")
        let id = try XCTUnwrap(store.snapshot.accounts["alpha"]?.id)
        XCTAssertEqual(try secrets.token(id: id), "tok-alpha", "the token is trimmed")
        store.mutate { $0.hold("alpha", hours: 1, now: 1_800_000_000) }

        let attrs = try FileManager.default.attributesOfItem(atPath: store.stateURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let text = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertFalse(text.contains("tok-"))
        XCTAssertEqual(CCPoolStore(directory: store.directory).snapshot, store.snapshot, "state survives a reload")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0 != "state.json" }
        XCTAssertEqual(leftovers, [], "no temp file left behind")

        try store.removeAccount(label: "alpha", secrets: secrets)
        XCTAssertNil(try secrets.token(id: id))
        XCTAssertEqual(store.snapshot.order, ["beta"])
        XCTAssertThrowsError(try store.removeAccount(label: "alpha", secrets: secrets))
    }

    // N1: an undecodable state file is moved aside, never overwritten, and logged without its path.
    func testStoreMovesUndecodableStateAside() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data(#"{"accounts": {"alpha": "#.utf8)
        try garbage.write(to: dir.appendingPathComponent("state.json"))
        let log = CCPoolCapturingLogger()
        let store = CCPoolStore(directory: dir, clock: { 1_800_000_000 }, logger: log)
        XCTAssertEqual(store.snapshot, CCPoolState())
        let aside = dir.appendingPathComponent("state.json.corrupt-1800000000")
        XCTAssertEqual(try Data(contentsOf: aside), garbage, "the original bytes are kept")
        XCTAssertEqual(log.lines.count, 1, log.lines.joined(separator: "\n"))
        XCTAssertFalse(log.lines.joined().contains(dir.path))
        try store.addAccount(label: "beta", token: "tok-beta", secrets: CCPoolMemorySecrets())
        XCTAssertEqual(try Data(contentsOf: aside), garbage, "a later write leaves it alone")
        XCTAssertEqual(CCPoolStore(directory: dir).snapshot.order, ["beta"])
    }

    // N2: the duplicate check is decided inside the mutation; a racing add of the same label wins.
    func testStoreAddDuplicateDecidedUnderLock() throws {
        final class Racing: CCPoolSecrets, @unchecked Sendable {
            let inner = CCPoolMemorySecrets(), outer = CCPoolMemorySecrets()
            var pool: CCPoolStore?
            var raced = false
            func store(token: String, id: String, label: String) throws {
                try outer.store(token: token, id: id, label: label)
                if !raced, let s = pool {
                    raced = true
                    try s.addAccount(label: label, token: "tok-inner", secrets: inner)
                }
            }
            func token(id: String) throws -> String? { try outer.token(id: id) }
            func remove(id: String) throws { try outer.remove(id: id) }
        }
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let racing = Racing()
        racing.pool = store
        XCTAssertThrowsError(try store.addAccount(label: "alpha", token: "tok-outer", secrets: racing)) {
            XCTAssertEqual($0 as? CCPoolStoreError, .duplicateLabel)
        }
        XCTAssertEqual(store.snapshot.order, ["alpha"], "listed once")
        XCTAssertEqual(racing.outer.count, 0, "the losing token is removed")
        XCTAssertEqual(racing.inner.count, 1)
        let id = try XCTUnwrap(store.snapshot.accounts["alpha"]?.id)
        XCTAssertEqual(try racing.inner.token(id: id), "tok-inner")
    }

    // N3: a failed state write is logged, without the path.
    func testStoreLogsFailedWrite() throws {
        let blocker = tempDir().appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let dir = blocker.appendingPathComponent("ccpool")
        let log = CCPoolCapturingLogger()
        let store = CCPoolStore(directory: dir, logger: log)
        store.mutate { $0.current = "alpha" }
        XCTAssertEqual(store.snapshot.current, "alpha", "memory still holds the change")
        XCTAssertTrue(log.lines.contains { $0.contains("state write failed") }, log.lines.joined(separator: "\n"))
        XCTAssertFalse(log.lines.joined().contains(blocker.path))
    }
}
