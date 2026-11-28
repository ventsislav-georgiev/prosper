import XCTest
@testable import ProsperApp

// #1261: a new or moving conversation is placed by the capacity score of ccpool v1.9.0 (ccpool_proxy.py place()
// 150-166, util_now 215-217, capacity 220-226). Pure rows on values (no server, no wait, no clock), plus two store
// rows in the row's tempDir() for the riders R1260-g and R1260-f. Fakes only. Capacities are binary-exact
// (dollars and points in quarters), so every score below is exact.

private let orgA = "Example Org A", orgB = "Example Org B", orgC = "Example Org C"
private let t0: Double = 1_800_000_000
private let later: Double = t0 + 3600
private let opus = "claude-opus-5"

private func id(_ name: String) -> String { "id-example-" + String(name.suffix(1)).lowercased() }

/// A sampled row in the window `later`: `dollars` over `points` (capacity dollars / points), running max `util`.
private func row(cap dollars: Double = 0.25, points: Double = 0.25, util: Double = 0, reset: Double = later) -> AgentPoolCapacityState {
    AgentPoolCapacityState(reset: reset, maxUtilization: util, pendingDollars: 0, dollars: dollars, points: points)
}

/// A pool in `order`; rows, five-hour resets and benches by name; pins "key": account, seen 5 s ago unless given.
private func pool(_ order: [String] = [orgA, orgB, orgC], current: String? = orgA, rows: [String: AgentPoolCapacityState] = [:],
                  resets: [String: Int] = [:], bench: Set<String> = [], pins: [String: String] = [:],
                  seen: [String: Double] = [:]) -> AgentPoolState {
    var accounts: [String: AgentPoolState.Account] = [:]
    for n in order {
        accounts[n] = AgentPoolState.Account(id: id(n), cooldown: bench.contains(n) ? [AgentPoolCore.fiveHour: Int(t0) + 600] : [:],
                                          reset: resets[n].map { [AgentPoolCore.fiveHour: $0] } ?? [:])
    }
    var st = AgentPoolState(current: current, order: order, accounts: accounts,
                         pins: pins.mapValues { AgentPoolState.Pin(account: $0, seen: t0 - 5) })
    for (k, s) in seen { st.pins[k]?.seen = s }
    for (n, r) in rows { st.capacity[id(n)] = r }
    return st
}

private func place(_ st: AgentPoolState, exclude: Set<String> = []) -> String? {
    AgentPoolCore.place(st, model: opus, exclude: exclude, now: t0)
}

private func route(_ st: AgentPoolState, _ key: String?, quota: Bool = false, exclude: Set<String> = [])
    -> (account: String?, state: AgentPoolState, followed: Bool) {
    AgentPoolCore.route(st, key: key, quotaCheck: quota, model: opus, exclude: exclude, now: t0)
}

/// `n` live sessions (one conversation each) pinned to `account`.
private func sessions(_ n: Int, on account: String, from first: Int = 1) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (0..<n).map { ("sess-example-\(first + $0)/", account) })
}

final class AgentPoolPlacementTests: XCTestCase {

    // MARK: The reference's place cases, ported (test_ccpool_proxy.py)

    /// Ports :315-318 "three sessions land on three accounts", "a session's subagent joins it there", "and the
    /// session stays put". No learned numbers: every capacity is 1.0, so the live sessions decide, then the order.
    func testReferenceThreeSessionsLandOnThreeAccounts() {
        var st = pool()
        for (sid, want) in [("sess-example-1/", orgA), ("sess-example-2/", orgB), ("sess-example-3/", orgC)] {
            let r = route(st, sid)
            XCTAssertEqual(r.account, want, sid)
            XCTAssertFalse(r.followed, sid)
            st = r.state
        }
        XCTAssertEqual(st.pins.mapValues(\.account), ["sess-example-1/": orgA, "sess-example-2/": orgB, "sess-example-3/": orgC])
        let sub = route(st, "sess-example-1/agent-example-1")
        XCTAssertEqual(sub.account, orgA, "the subagent joins its session")
        XCTAssertTrue(sub.followed)
        XCTAssertEqual(route(st, "sess-example-1/").account, orgA, "and the session stays put")
        XCTAssertEqual(st.current, orgA, "route never moves current; the reply of a placement does")
    }

    /// Ports :326-333: the session's account runs out (benched); the session moves to the best other, its subagent
    /// follows it there (not a fresh placement), the other sessions stay.
    func testReferenceSpentAccountMovesItsSessionOnly() {
        let st = pool(bench: [orgA], pins: ["sess-example-1/": orgA, "sess-example-2/": orgB, "sess-example-3/": orgC])
        let moved = route(st, "sess-example-1/")
        XCTAssertEqual(moved.account, orgB, "B and C both hold one session: a tie, B first by label")
        XCTAssertFalse(moved.followed)
        XCTAssertEqual(route(moved.state, "sess-example-1/agent-example-1").account, orgB, "its subagent follows it")
        XCTAssertEqual(route(moved.state, "sess-example-2/").account, orgB)
        XCTAssertEqual(route(moved.state, "sess-example-3/").account, orgC)
    }

    /// Ports :335-338 "a session idle on its user still holds its account": a pin 600 s old counts as live.
    func testReferenceIdlePinWithinTheHourStillCounts() {
        let st = pool([orgA, orgB], pins: ["sess-example-9/": orgA], seen: ["sess-example-9/": t0 - 600])
        XCTAssertEqual(route(st, "sess-example-1/").account, orgB)
    }

    /// Ports :339-344 "a new session skips a nearly full account" and "unless every account is nearly full".
    func testReferenceNearlyFullAccountIsSkippedUnlessAllAre() {
        XCTAssertEqual(place(pool(rows: [orgA: row(util: 0.95)])), orgB)
        let all = pool(rows: [orgA: row(util: 0.95), orgB: row(util: 0.95), orgC: row(util: 0.95)])
        XCTAssertEqual(place(all), orgA, "all equal: still placed, by label")
    }

    /// Ports :365-372 "a new session goes to the bigger plan, even part used" and "the small plan is last while a bigger
    /// one has headroom". A learned 12 $/pt, B 1 $/pt, C unknown (the median of the known, upper: 12).
    /// Scores: A 0.75 x 12 = 9, B 1 x 1 = 1, C 0.875 x 12 = 10.5 with "x/" pinned there: 5.25.
    func testReferenceBiggerPlanWinsEvenPartUsed() {
        var st = pool(rows: [orgA: row(cap: 3, util: 0.25), orgB: row(cap: 0.25, util: 0), orgC: row(cap: 0, points: 0, util: 0.125)],
                      pins: ["x/": orgC])
        for (sid, want) in [("sess-example-1/", orgA), ("sess-example-2/", orgC), ("sess-example-3/", orgA)] {
            // A: 9, then 4.5; C: 5.25; then A 4.5 vs C 3.5.
            let r = route(st, sid)
            XCTAssertEqual(r.account, want, sid)
            st = r.state
        }
        XCTAssertFalse(st.pins.values.contains { $0.account == orgB }, "the small plan is last")
    }

    // MARK: The score

    /// Two plans 12x apart (12 $/pt and 1 $/pt, both empty): the large one scores 12 / (n + 1) with n live sessions,
    /// the small one 1. n = 0: 12 > 1; n = 10: 12/11 > 1; n = 11: 12/12 = 1, a tie: the label decides (#1838); n = 12: 12/13 < 1.
    func testTwelveFoldPlanTakesElevenSessionsBeforeTheSmallOneGetsOne() {
        let rows = [orgA: row(cap: 3), orgB: row(cap: 0.25)]
        for (n, want) in [(0, orgA), (10, orgA), (11, orgA), (12, orgB)] {
            XCTAssertEqual(place(pool([orgA, orgB], rows: rows, pins: sessions(n, on: orgA))), want, "n = \(n)")
        }
        XCTAssertEqual(place(pool([orgB, orgA], rows: rows, pins: sessions(11, on: orgA))), orgA,
                       "#1838: the tie goes by label, whatever `order` holds")
    }

    /// A at 4 $/pt: no session 4, one session 4/2 = 2, two sessions 4/3. B at 2 ties with one, B at 1.5 sits between.
    func testOneMoreLiveSessionDividesTheScoreByItsCount() {
        let at2 = [orgA: row(cap: 1), orgB: row(cap: 0.5)]
        XCTAssertEqual(place(pool([orgA, orgB], rows: at2)), orgA, "4 > 2")
        XCTAssertEqual(place(pool([orgA, orgB], rows: at2, pins: sessions(1, on: orgA))), orgA, "2 = 2: the label (#1838)")
        XCTAssertEqual(place(pool([orgB, orgA], rows: at2, pins: sessions(1, on: orgA))), orgA, "2 = 2: the label, whatever `order` holds")
        let at15 = [orgA: row(cap: 1), orgB: row(cap: 0.375)]
        XCTAssertEqual(place(pool([orgA, orgB], rows: at15, pins: sessions(1, on: orgA))), orgA, "2 > 1.5")
        XCTAssertEqual(place(pool([orgA, orgB], rows: at15, pins: sessions(2, on: orgA))), orgB, "4/3 < 1.5")
    }

    /// One session with its main conversation and a subagent counts once: A 4/2 = 2 > B 1.5 (twice would be 4/3 < 1.5).
    func testTwoConversationsOfOneSessionCountOnce() {
        let st = pool([orgA, orgB], rows: [orgA: row(cap: 1), orgB: row(cap: 0.375)],
                      pins: ["sess-example-1/": orgA, "sess-example-1/agent-example-1": orgA])
        XCTAssertEqual(place(st), orgA)
    }

    /// A pin idle more than an hour is not live: A keeps 4 > B 2.5; exactly an hour is still live: 2 < 2.5.
    func testExpiredPinDoesNotCountAndTheInputIsUntouched() {
        let rows = [orgA: row(cap: 1), orgB: row(cap: 0.625)]
        let expired = pool([orgA, orgB], rows: rows, pins: ["sess-example-1/": orgA], seen: ["sess-example-1/": t0 - 3601])
        XCTAssertEqual(place(expired), orgA)
        XCTAssertEqual(expired.pins["sess-example-1/"]?.seen, t0 - 3601, "a lookup changes nothing")
        let edge = pool([orgA, orgB], rows: rows, pins: ["sess-example-1/": orgA], seen: ["sess-example-1/": t0 - 3600])
        XCTAssertEqual(place(edge), orgB)
    }

    /// A at 90% in a window that rolled over (reset at or before now) counts 0: 1 = B's 1 (the median), order: A.
    /// The same 90% while the window is ahead: 0.1 < 1: B.
    func testRolledOverWindowCountsZero() {
        XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: row(util: 0.9, reset: t0)])), orgA)
        XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: row(util: 0.9, reset: t0 - 100)])), orgA)
        XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: row(util: 0.9, reset: t0 + 1)])), orgB)
    }

    /// Equal scores: the soonest five-hour reset (pick's resetAt: a past or unseen one is +inf), then the order.
    func testTieGoesToTheSoonerResetThenToTheOrder() {
        XCTAssertEqual(place(pool()), orgA)
        XCTAssertEqual(place(pool(resets: [orgB: Int(t0) + 100, orgC: Int(t0) + 50])), orgC)
        XCTAssertEqual(place(pool(resets: [orgB: Int(t0) + 50, orgC: Int(t0) + 50])), orgB)
        XCTAssertEqual(place(pool(resets: [orgA: Int(t0) - 1, orgC: Int(t0) + 50])), orgC, "a past reset is unseen")
    }

    // MARK: Never wider than pick

    func testExcludedBenchedAndOutsideAccountsAreNeverReturned() {
        let rows = [orgA: row(cap: 3), orgB: row(cap: 0.5), orgC: row()]   // 12, 2, 1
        XCTAssertEqual(place(pool(rows: rows)), orgA)
        XCTAssertEqual(place(pool(rows: rows, bench: [orgA])), orgB, "benched")
        XCTAssertEqual(place(pool(rows: rows), exclude: [orgA]), orgB, "excluded")
        var gone = pool(rows: rows)
        gone.accounts.removeValue(forKey: orgA)
        XCTAssertEqual(place(gone), orgB, "listed but not in the pool")
        var unlisted = pool(rows: rows)
        unlisted.order = [orgB, orgC]
        XCTAssertEqual(place(unlisted), orgB, "in the pool but not listed")
        XCTAssertTrue(place(pool(rows: rows, bench: [orgA, orgB, orgC])) == nil)
        XCTAssertTrue(place(pool(rows: rows), exclude: [orgA, orgB, orgC]) == nil)
        XCTAssertTrue(place(pool([])) == nil)
    }

    /// For a table of states, the answer is one of the names pick could return (in the pool, listed, not excluded,
    /// eligible), and there is an answer exactly when pick has one.
    func testAnswerIsAlwaysAnEligibleNotExcludedName() {
        let names = [orgA, orgB, orgC]
        let rowSets: [[String: AgentPoolCapacityState]] = [[:], [orgA: row(cap: 3)], [orgB: row(cap: 3, util: 1)],
                                                        [orgC: row(cap: .nan)], [orgA: row(cap: 3), orgC: row(util: -1)]]
        var checked = 0
        for mask in 0..<64 {
            let bench = Set(names.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let exclude = Set(names.enumerated().filter { mask & (8 << $0.offset) != 0 }.map(\.element))
            for rows in rowSets {
                let st = pool(rows: rows, bench: bench, pins: sessions(2, on: orgA))
                let allowed = Set(names).subtracting(bench).subtracting(exclude)
                let got = place(st, exclude: exclude)
                XCTAssertTrue(got.map { allowed.contains($0) } ?? allowed.isEmpty, "\(bench) \(exclude) \(got ?? "nil")")
                XCTAssertEqual(got == nil, AgentPoolCore.pick(st, model: opus, exclude: exclude, now: t0) == nil)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 320)
    }

    /// An account at or above 100% is never placed on while another eligible one is below it, even one scoring 0
    /// (capacity 0). All there: one is still placed (the reference does too), by reset, then order.
    func testFullAccountIsNotPlacedOnWhileAnotherIsBelow() {
        XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: row(cap: 3, util: 1), orgB: row(cap: 0.25)],
                                  pins: sessions(5, on: orgB))), orgB, "12 x 0 = 0 < 1/6")
        XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: row(cap: 3, util: 1), orgB: row(cap: 0)])), orgB,
                       "B scores 0 too but is below 100%")
        XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: row(cap: 3, util: 1.5), orgB: row(cap: 0.25)])), orgB)
        let both = [orgA: row(util: 1), orgB: row(util: 1.25)]
        XCTAssertEqual(place(pool([orgA, orgB], rows: both)), orgA, "all full: order")
        XCTAssertEqual(place(pool([orgA, orgB], rows: both, resets: [orgB: Int(t0) + 60])), orgB, "all full: sooner reset")
    }

    /// Rows built in memory with a NaN, an infinity or a negative: no trap, and the account never wins over a sane one
    /// (B: no row, capacity 1). Alone, it is still placed (eligible is the only gate).
    func testBadNumbersNeverTrapAndNeverWin() {
        let bad: [(String, AgentPoolCapacityState)] = [
            ("NaN dollars", row(cap: .nan)), ("NaN points", row(points: .nan)), ("NaN max", row(cap: 3, util: .nan)),
            ("inf dollars", row(cap: .infinity)), ("inf points", row(cap: 3, points: .infinity)),
            ("-inf max", row(cap: 3, util: -.infinity)), ("inf reset", row(cap: 3, reset: .infinity)),
            ("NaN reset", row(cap: 3, reset: .nan)), ("negative max", row(cap: 3, util: -1)),
            ("negative dollars", row(cap: -3)), ("negative points", row(cap: 3, points: -0.25)),
            ("huge dollars", row(cap: 2e12)), ("max above the cap", row(cap: 3, util: 11)),
        ]
        for (why, r) in bad {
            XCTAssertEqual(place(pool([orgA, orgB], rows: [orgA: r])), orgB, why)
            XCTAssertEqual(place(pool([orgB, orgA], rows: [orgA: r], pins: sessions(3, on: orgB))), orgB, why)
            XCTAssertEqual(place(pool([orgA], rows: [orgA: r])), orgA, "alone: \(why)")
            // A bad row of a third account does not move the median the others read: C 4 $/pt wins over A unknown.
            XCTAssertEqual(place(pool([orgA, orgB, orgC], rows: [orgB: r, orgC: row(cap: 1)], pins: sessions(1, on: orgC))),
                           orgA, "median of the sane rows: A = 4 > C 2: \(why)")
        }
    }

    // MARK: route

    /// A new key goes to the best score (B 4 $/pt over A, current, at 1) and is pinned there; route leaves current.
    func testNewKeyIsPlacedByTheScoreAndPinnedThere() {
        let st = pool([orgA, orgB], rows: [orgA: row(), orgB: row(cap: 1)])
        XCTAssertEqual(AgentPoolCore.pick(st, model: opus, exclude: [], now: t0), orgA, "pick would keep current")
        let r = route(st, "sess-example-1/")
        XCTAssertEqual(r.account, orgB)
        XCTAssertFalse(r.followed)
        XCTAssertEqual(r.state.pins.mapValues(\.account), ["sess-example-1/": orgB])
        XCTAssertEqual(r.state.current, orgA)
    }

    /// A usable pin wins over any score (A pinned, B 12 $/pt), for a request and a quota check, main and subagent.
    func testPinnedKeyFollowsItsPinWhateverTheScores() {
        let st = pool([orgA, orgB], rows: [orgA: row(cap: 0.25, util: 0.9), orgB: row(cap: 3)], pins: ["sess-example-1/": orgA])
        for quota in [false, true] {
            let r = route(st, "sess-example-1/", quota: quota)
            XCTAssertEqual(r.account, orgA, "\(quota)")
            XCTAssertTrue(r.followed)
            XCTAssertEqual(r.state, st)
        }
        XCTAssertEqual(route(st, "sess-example-1/agent-example-1").account, orgA)
    }

    /// No usable key: pick's answer, current, exactly as AgentPoolPinRoutingTests.testNoKeyFollowsCurrentAndChangesNothing.
    func testNoKeyGetsPicksAnswer() {
        let st = pool([orgA, orgB], rows: [orgB: row(cap: 3)], pins: ["sess-example-9/": orgA])
        for key in [nil, "", "sess example-1/"] as [String?] {
            let r = route(st, key)
            XCTAssertEqual(r.account, orgA, key ?? "nil")
            XCTAssertEqual(r.state, st)
        }
    }

    /// A quota check is placed like a request (the reference's choose(stick=False)) but makes no pin.
    func testQuotaCheckIsPlacedButMakesNoPin() {
        let st = pool([orgA, orgB], rows: [orgA: row(), orgB: row(cap: 1)])
        let q = route(st, "sess-example-1/", quota: true)
        XCTAssertEqual(q.account, orgB)
        XCTAssertTrue(q.state.pins.isEmpty)
        XCTAssertEqual(q.state, st)
    }

    /// The one move after a refusal (A in exclude): the best other by score (C 4 $/pt over B 1, first in order and
    /// pick's answer), never A again however big.
    func testMoveAfterARefusalIsPlacedWithTheRefusingAccountExcluded() {
        let st = pool(rows: [orgA: row(cap: 3), orgB: row(), orgC: row(cap: 1)], pins: ["sess-example-1/": orgA])
        XCTAssertEqual(AgentPoolCore.pick(st, model: opus, exclude: [orgA], now: t0), orgB)
        let r = route(st, "sess-example-1/", exclude: [orgA])
        XCTAssertEqual(r.account, orgC)
        XCTAssertFalse(r.followed)
        XCTAssertEqual(r.state.pins.mapValues(\.account), ["sess-example-1/": orgC])
    }

    /// A benched account with the biggest score never gets a new key; route falls to the next by score.
    func testBenchedAccountGetsNoNewKey() {
        let st = pool(rows: [orgA: row(cap: 3), orgB: row(), orgC: row(cap: 1)], bench: [orgA])
        XCTAssertEqual(route(st, "sess-example-1/").account, orgC)
    }

    // MARK: The riders of entry 1260 (store rows; the state file in tempDir())

    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// R1260-g / R1260-q1: a row the check refuses (a non-finite number, a total past 1e12) is not written, and the
    /// save of everything else still happens; the file reads back with the sane row only.
    func testUncheckedRowIsNotWrittenAndTheSaveStillHappens() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let s = AgentPoolStore(directory: dir, clock: { t0 })
        let secrets = AgentPoolMemorySecrets()
        let a = try s.addAccount(label: orgA, token: "tok-example-a", secrets: secrets)
        let b = try s.addAccount(label: orgB, token: "tok-example-b", secrets: secrets)
        let c = try s.addAccount(label: orgC, token: "tok-example-c", secrets: secrets)
        s.mutate { st in
            st.capacity[a] = row(cap: .infinity)
            st.capacity[b] = row(cap: 2e12)
            st.capacity[c] = row(cap: 1)
            st.current = orgC
        }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: s.stateURL)) as? [String: Any]
        XCTAssertEqual(obj?["current"] as? String, orgC, "the save happened")
        XCTAssertEqual((obj?["capacity"] as? [String: Any]).map { Set($0.keys) }, [c], "only the checked row")
        let again = AgentPoolStore(directory: dir, clock: { t0 }).snapshot
        XCTAssertTrue(again.capacity == [c: row(cap: 1)], "\(again.capacity)")
        XCTAssertEqual(again.current, orgC)
    }

    /// R1260-f: a row for an id that is no longer in the pool is not part of the file, so it rewrites nothing.
    func testRowOfAnIdOutsideThePoolWritesNothing() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let writes = Writes()
        let s = AgentPoolStore(directory: dir, clock: { t0 }, writer: { data, url in writes.bump(); return AgentPoolStore.atomicWrite(data, url) })
        _ = try s.addAccount(label: orgA, token: "tok-example-a", secrets: AgentPoolMemorySecrets())
        let file = try Data(contentsOf: s.stateURL)
        let w = writes.value
        s.mutate { $0.capacity["id-example-gone"] = row(cap: 1) }
        XCTAssertEqual(writes.value, w, "no write")
        XCTAssertEqual(try Data(contentsOf: s.stateURL), file)
    }

    // MARK: #1677 the share (the pane's "Move off an account at") is a soft preference

    /// A 12 $/pt at 0.85 scores 1.8, B 1 $/pt at 0.3 scores 0.7: the score takes A; a share of 0.8 takes B (A is over
    /// it); 0.9 takes A again (both under). A share never turns an answer into none.
    func testShareSteersANewPlacementToTheAccountUnderIt() {
        let st = pool([orgA, orgB], rows: [orgA: row(cap: 3, util: 0.85), orgB: row(cap: 0.25, util: 0.3)])
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0, share: 1.0), orgA)
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0, share: 0.8), orgB)
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0, share: 0.9), orgA)
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [orgB], now: t0, share: 0.8), orgA, "only A left: still placed")
        XCTAssertEqual(AgentPoolCore.route(st, key: "sess-example-1/", quotaCheck: false, model: opus, exclude: [], now: t0,
                                        share: 0.8).account, orgB)
    }

    /// Every account at or over the share: placed exactly as without it (score, then the full ones last).
    func testEveryAccountOverTheSharePlacesAsToday() {
        let cases: [[String: AgentPoolCapacityState]] = [
            [orgA: row(cap: 3, util: 0.85), orgB: row(cap: 0.25, util: 0.9)],
            [orgA: row(cap: 0.25, util: 0.85), orgB: row(cap: 3, util: 0.9)],
            [orgA: row(cap: 3, util: 1), orgB: row(cap: 0.25, util: 0.9)],
            [orgA: row(util: 0.8), orgB: row(util: 0.8)],
        ]
        for rows in cases {
            let st = pool([orgA, orgB], rows: rows)
            XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0, share: 0.8), place(st), "\(rows)")
        }
        let full = pool([orgA, orgB], rows: [orgA: row(cap: 3, util: 1), orgB: row(cap: 0.25, util: 0.9)])
        XCTAssertEqual(AgentPoolCore.place(full, model: opus, exclude: [], now: t0, share: 0.8), orgB, "a full account is still last")
    }

    /// A pin on an account over the share is followed: no move for the share alone.
    func testShareNeverMovesAPinnedConversation() {
        let st = pool([orgA, orgB], rows: [orgA: row(util: 0.85), orgB: row(util: 0.1)], pins: ["sess-example-1/": orgA])
        let r = AgentPoolCore.route(st, key: "sess-example-1/", quotaCheck: false, model: opus, exclude: [], now: t0, share: 0.5)
        XCTAssertEqual(r.account, orgA)
        XCTAssertTrue(r.followed)
        let sub = AgentPoolCore.route(st, key: "sess-example-1/agent-example-1", quotaCheck: false, model: opus, exclude: [], now: t0,
                                   share: 0.5)
        XCTAssertEqual(sub.account, orgA, "a subagent follows its session")
    }

    /// The share reads the same number the score does: a rolled-over window is 0, so under any share.
    func testShareReadsTheLiveWindowOnly() {
        let st = pool([orgA, orgB], rows: [orgA: row(cap: 3, util: 0.95, reset: t0 - 1), orgB: row(cap: 0.25, util: 0.1)])
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0, share: 0.5), orgA)
    }

    // MARK: #1855: an account that just refused a placement (a 429 that spent nothing) ranks last for a short window

    /// Shunned A ranks after B and C, after a FULL account too; at the window's end (exactly) it is back; never excluded:
    /// all shunned, or the others excluded, still answers.
    func testShunnedAccountRanksAfterEveryOtherUntilItsWindowEnds() {
        var st = pool()
        XCTAssertEqual(place(st), orgA, "the label tie without a shun")
        st.shun(orgA, seconds: 30, now: t0)
        XCTAssertEqual(place(st), orgB, "A just refused: B")
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0 + 29.5), orgB, "still inside the window")
        XCTAssertEqual(AgentPoolCore.place(st, model: opus, exclude: [], now: t0 + 30), orgA, "the window ended: A again")
        let full = { () -> AgentPoolState in
            var f = pool([orgA, orgB], rows: [orgA: row(cap: 3), orgB: row(cap: 0.25, util: 1)])
            f.shun(orgA, seconds: 30, now: t0)
            return f
        }()
        XCTAssertEqual(place(full), orgB, "a shunned account ranks after a full one")
        XCTAssertEqual(place(st, exclude: [orgB, orgC]), orgA, "a shun never excludes")
        st.shun(orgB, seconds: 30, now: t0)
        st.shun(orgC, seconds: 30, now: t0)
        XCTAssertEqual(place(st), orgA, "all shunned: the order without the shun")
    }

    /// A pin is followed whatever the shun (place only), and a shun is memory only: not encoded, not part of ==.
    func testShunIsMemoryOnlyAndNeverStopsAPin() throws {
        var st = pool(pins: ["sess-example-1/": orgA])
        let before = st
        st.shun(orgA, seconds: 30, now: t0)
        XCTAssertEqual(route(st, "sess-example-1/").account, orgA, "a pin is followed")
        XCTAssertTrue(st == before, "== ignores the shun, so the store writes nothing for it")
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let text = String(decoding: try enc.encode(st), as: UTF8.self)
        XCTAssertFalse(text.contains("shun"), text)
        XCTAssertEqual(text, String(decoding: try enc.encode(before), as: UTF8.self))
    }

    /// The window: Retry-After when 1...60 s, else 30 s. A longer existing shun is kept; an unknown label is ignored;
    /// expired entries are dropped on the next shun, so the map stays small.
    func testShunWindowAndBookkeeping() {
        let rows: [(String?, Int)] = [(nil, 30), ("1", 1), ("7", 7), ("60", 60), ("61", 30), ("0", 30), ("-3", 30),
                                      ("3600", 30), ("soon", 30), (" 12 ", 12), ("99999999999999999999", 30)]
        for (raw, want) in rows { XCTAssertEqual(AgentPoolCore.shunSeconds(retryAfter: raw), want, raw ?? "nil") }
        var st = pool()
        st.shun(orgA, seconds: 60, now: t0)
        st.shun(orgA, seconds: 5, now: t0)
        XCTAssertEqual(st.shunned, [orgA: t0 + 60], "never shortened")
        st.shun("Example Org Gone", seconds: 30, now: t0)
        XCTAssertEqual(st.shunned, [orgA: t0 + 60], "a label outside the pool is ignored")
        st.shun(orgB, seconds: 10, now: t0 + 61)
        XCTAssertEqual(st.shunned, [orgB: t0 + 71], "the expired entry went")
        st.shun(orgC, seconds: 10, now: .nan)
        XCTAssertEqual(st.shunned, [orgB: t0 + 71], "a bad clock changes nothing")
    }
}
