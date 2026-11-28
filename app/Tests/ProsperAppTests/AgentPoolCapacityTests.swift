import XCTest
@testable import ProsperApp

// #1257: ports of the capacity cases of ccpool 1.9.0 (test_ccpool_proxy.py 335-383), literal expectations.
final class AgentPoolCapacityTests: XCTestCase {
    private typealias C = AgentPoolCapacity
    private let window = 5000.0

    private func feed(_ s: AgentPoolCapacityState, output: Double, utils: [Double], reset: Double = 5000) -> AgentPoolCapacityState {
        utils.reduce(s) { C.learn($0, model: "claude-opus-5-5", usage: AgentPoolTokenUsage(output: output), utilization: $1, reset: reset) }
    }

    func testPriceTable() {
        let M = 1e6
        // model, usage, expected dollars (literals from the list prices and multipliers)
        let rows: [(String?, AgentPoolTokenUsage, Double)] = [
            ("claude-opus-5-5", AgentPoolTokenUsage(input: M), 4.0),
            ("claude-opus-5-5", AgentPoolTokenUsage(output: 50000), 1.0),
            ("claude-opus-5-5", AgentPoolTokenUsage(cacheRead: M), 0.2),
            ("claude-sonnet-5", AgentPoolTokenUsage(input: M), 2.0),
            ("claude-sonnet-5", AgentPoolTokenUsage(output: M), 10.0),
            ("claude-sonnet-5", AgentPoolTokenUsage(cacheRead: M), 0.1),
            ("claude-sonnet-5", AgentPoolTokenUsage(cacheWrite5m: M), 2.5),
            ("claude-sonnet-5", AgentPoolTokenUsage(cacheWrite1h: M), 4.0),
            ("claude-haiku-4", AgentPoolTokenUsage(output: M), 0.5),
            ("claude-haiku-4", AgentPoolTokenUsage(input: M), 0.1),
            ("claude-haiku-4", AgentPoolTokenUsage(cacheRead: M), 0.01),
            ("fable-1", AgentPoolTokenUsage(output: M), 40.0),
            ("mythos-1", AgentPoolTokenUsage(input: M), 8.0),
            ("mythos-1", AgentPoolTokenUsage(cacheWrite1h: M), 16.0),
            ("gpt-unknown", AgentPoolTokenUsage(input: M), 4.0),   // unknown model: opus
            (nil, AgentPoolTokenUsage(input: M), 4.0),
            ("", AgentPoolTokenUsage(output: M), 20.0),
            ("claude-opus-5-5", AgentPoolTokenUsage(input: 1000, output: 2000, cacheRead: 3000, cacheWrite5m: 4000, cacheWrite1h: 5000), 0.1046),
            ("claude-opus-5-5", AgentPoolTokenUsage(), 0.0),
        ]
        for (model, usage, want) in rows {
            let got = C.dollars(model: model, usage: usage)
            XCTAssertTrue(got != nil, "\(String(describing: model))")
            XCTAssertEqual(got ?? -1, want, accuracy: 1e-9, "\(String(describing: model)) \(usage)")
        }
    }

    func testCapacityIsLearnedFromSpendPerPoint() {
        // 6 rises of 0.01: one spends 1200 opus output tokens ($0.024) per rise, two spends 100 ($0.002).
        let utils = [0.10, 0.11, 0.12, 0.13, 0.14, 0.15, 0.16]
        let one = feed(AgentPoolCapacityState(), output: 1200, utils: utils)
        let two = feed(AgentPoolCapacityState(), output: 100, utils: utils)
        XCTAssertEqual(one.dollars, 0.144, accuracy: 1e-9)
        XCTAssertEqual(one.points, 0.06, accuracy: 1e-9)
        XCTAssertEqual(C.capacity(of: one, among: [one, two]), 2.4, accuracy: 1e-6)
        XCTAssertEqual(C.capacity(of: two, among: [one, two]), 0.2, accuracy: 1e-6)
        XCTAssertEqual(C.capacity(of: one, among: [one, two]) / C.capacity(of: two, among: [one, two]), 12, accuracy: 0.01)
    }

    func testWobbleBelowTheRunningMaxLearnsNothing() {
        let one = feed(AgentPoolCapacityState(), output: 1200, utils: [0.10, 0.11, 0.12, 0.13, 0.14, 0.15, 0.16])
        let after = feed(one, output: 0, utils: [0.15, 0.14, 0.15, 0.14, 0.15])
        XCTAssertEqual(after.dollars, one.dollars)
        XCTAssertEqual(after.points, one.points)
        XCTAssertEqual(after.maxUtilization, 0.16, accuracy: 1e-12)
        // a fall keeps its dollars pending: they join the next real rise
        let fell = feed(one, output: 1200, utils: [0.12])
        XCTAssertEqual(fell.pendingDollars, 0.024, accuracy: 1e-9)
        let rose = feed(fell, output: 0, utils: [0.17])
        XCTAssertEqual(rose.dollars, 0.168, accuracy: 1e-9)
        XCTAssertEqual(rose.points, 0.07, accuracy: 1e-9)
    }

    func testFirstSampleAndEqualUtilizationCountNothing() {
        let first = feed(AgentPoolCapacityState(), output: 1200, utils: [0.30])
        XCTAssertEqual(first.points, 0)
        XCTAssertEqual(first.dollars, 0)
        XCTAssertEqual(first.reset, 5000)
        let same = feed(first, output: 1200, utils: [0.30])
        XCTAssertEqual(same.points, 0)
        XCTAssertEqual(same.pendingDollars, 0.024, accuracy: 1e-9)
    }

    func testARiseBelowTheMinimumIsKeptButNotUsedByTheRead() {
        // reference: any rise counts (0.04 here), the 0.05 floor is on the read
        let small = feed(AgentPoolCapacityState(), output: 1200, utils: [0.10, 0.14])
        XCTAssertEqual(small.points, 0.04, accuracy: 1e-9)
        XCTAssertEqual(C.capacity(of: small, among: [small]), 1.0)
        let big = feed(AgentPoolCapacityState(), output: 1200, utils: [0.10, 0.16])
        XCTAssertEqual(C.capacity(of: big, among: [big]), 0.4, accuracy: 1e-6)
        XCTAssertEqual(C.capacity(of: small, among: [small, big]), 0.4, accuracy: 1e-6)
    }

    func testANewWindowRestartsTheRunningMaxAndKeepsTheTotals() {
        let one = feed(AgentPoolCapacityState(), output: 1200, utils: [0.10, 0.15, 0.20])
        XCTAssertEqual(one.points, 0.10, accuracy: 1e-9)
        let rolled = feed(one, output: 1200, utils: [0.02], reset: 9000)
        XCTAssertEqual(rolled.reset, 9000)
        XCTAssertEqual(rolled.maxUtilization, 0.02, accuracy: 1e-12)
        XCTAssertEqual(rolled.pendingDollars, 0)
        XCTAssertEqual(rolled.points, one.points)
        XCTAssertEqual(rolled.dollars, one.dollars)
        let next = feed(rolled, output: 1200, utils: [0.07], reset: 9000)
        XCTAssertEqual(next.points, 0.15, accuracy: 1e-9)
        XCTAssertEqual(next.dollars, 0.048 + 0.024, accuracy: 1e-9)
    }

    func testRelearnedFromSevenRowsOfFiveHundredOutputTokens() {
        let utils = (0..<7).map { 0.2 + Double($0) / 100 }
        let two = feed(AgentPoolCapacityState(), output: 500, utils: utils, reset: 123)
        XCTAssertTrue(two.points >= 0.05)
        XCTAssertEqual(C.capacity(of: two, among: [two]), 1.0, accuracy: 0.01)
    }

    func testMedianDefaultWithZeroOneTwoAndThreeLearned() {
        func learned(_ dpp: Double) -> AgentPoolCapacityState { AgentPoolCapacityState(reset: 1, maxUtilization: 0.5, dollars: dpp * 0.1, points: 0.1) }
        let none = AgentPoolCapacityState()
        let a = learned(2), b = learned(5), c = learned(9)
        XCTAssertEqual(C.capacity(of: none, among: [none]), 1.0)
        XCTAssertEqual(C.capacity(of: nil, among: []), 1.0)
        XCTAssertEqual(C.capacity(of: none, among: [none, a]), 2.0, accuracy: 1e-9)
        XCTAssertEqual(C.capacity(of: none, among: [none, a, b]), 5.0, accuracy: 1e-9)   // upper median
        XCTAssertEqual(C.capacity(of: nil, among: [c, a, b]), 5.0, accuracy: 1e-9)
        XCTAssertEqual(C.capacity(of: a, among: [a, b, c]), 2.0, accuracy: 1e-9)       // own value wins
    }

    func testBadNumbersLeaveTheStateUnchanged() {
        let base = feed(AgentPoolCapacityState(), output: 1200, utils: [0.10, 0.12])
        let ok = AgentPoolTokenUsage(output: 1200)
        let bad: [(String, AgentPoolTokenUsage?, Double, Double)] = [
            ("negative utilization", ok, -0.1, 5000),
            ("nan utilization", ok, .nan, 5000),
            ("infinite utilization", ok, .infinity, 5000),
            ("absurd utilization", ok, 1e300, 5000),
            ("nan reset", ok, 0.5, .nan),
            ("negative reset", ok, 0.5, -1),
            ("negative tokens", AgentPoolTokenUsage(output: -5), 0.5, 5000),
            ("nan tokens", AgentPoolTokenUsage(input: .nan), 0.5, 5000),
            ("infinite tokens", AgentPoolTokenUsage(cacheRead: .infinity), 0.5, 5000),
            ("absurd tokens", AgentPoolTokenUsage(cacheWrite1h: 1e300), 0.5, 5000),
            ("absurd output", AgentPoolTokenUsage(output: 2e12), 0.5, 5000),
        ]
        for (name, usage, util, reset) in bad {
            XCTAssertEqual(C.learn(base, model: "claude-opus-5-5", usage: usage, utilization: util, reset: reset), base, name)
            XCTAssertEqual(C.learn(AgentPoolCapacityState(), model: nil, usage: usage, utilization: util, reset: reset), AgentPoolCapacityState(), name)
        }
        XCTAssertTrue(C.dollars(model: nil, usage: AgentPoolTokenUsage(output: -1)) == nil)
        XCTAssertTrue(C.dollars(model: nil, usage: AgentPoolTokenUsage(input: .nan)) == nil)
        XCTAssertTrue(C.dollars(model: nil, usage: AgentPoolTokenUsage(output: 1e13)) == nil)
        // a poisoned stored state never yields a non-finite capacity
        let poisoned = AgentPoolCapacityState(reset: 1, maxUtilization: 0, dollars: .infinity, points: 1)
        XCTAssertEqual(C.capacity(of: poisoned, among: [poisoned]), 1.0)
        XCTAssertEqual(C.capacity(of: nil, among: [AgentPoolCapacityState(dollars: .nan, points: .nan)]), 1.0)
    }

    /// #1910: place's rank reads a row with no reset as 0 used (AgentPoolCore.place). That is right only because such a
    /// row is the never-sampled one, at 0: learn sets the reset with any running max, and a state-file row without a
    /// number reset is dropped. A reply with no reset never reaches learn (AgentPoolConnection.learn's guard).
    func testRowWithoutResetIsOnlyTheUnsampledZero() throws {
        let inputs: [(Double, Double, Double)] = [(1200, 0.9, 5000), (1200, .nan, 5000), (1200, 0.9, .nan),
                                                  (-5, 0.9, 5000), (1200, 50, 5000), (0, 0.97, 0)]
        for (output, util, reset) in inputs {
            let s = C.learn(AgentPoolCapacityState(), model: nil, usage: AgentPoolTokenUsage(output: output), utilization: util, reset: reset)
            XCTAssertTrue(s.reset != nil || s.maxUtilization == 0, "\(output) \(util) \(reset)")
        }
        for json in [#"{"x":{"reset":null,"maxUtilization":0.9,"pendingDollars":0,"dollars":1,"points":1}}"#,
                     #"{"x":{"maxUtilization":0.9,"pendingDollars":0,"dollars":1,"points":1}}"#] {
            let rows = try JSONDecoder().decode([String: AgentPoolCapacityState.Row].self, from: Data(json.utf8))
            XCTAssertTrue(rows["x"]?.state == nil, json)
        }
    }

    func testStateCodableRoundTrip() throws {
        let s = feed(AgentPoolCapacityState(), output: 1200, utils: [0.10, 0.12, 0.15])
        let back = try JSONDecoder().decode(AgentPoolCapacityState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let fresh = try JSONDecoder().decode(AgentPoolCapacityState.self, from: JSONEncoder().encode(AgentPoolCapacityState()))
        XCTAssertEqual(fresh, AgentPoolCapacityState())
    }

    /// #1838 (session-tokens item 3): a never-measured account (no row, or under minPoints) is placed at once, at the
    /// median $/pt of the measured ones: the middle one for an odd count, the upper middle for an even one (Python's
    /// sorted(...)[len // 2]); none measured: 1.0. Measured: 1, 4, 2 (odd: 2), then 8 joins (even: 4).
    func testUnmeasuredAccountTakesTheMedianOfTheMeasured() {
        func measured(_ perPoint: Double) -> AgentPoolCapacityState {
            AgentPoolCapacityState(reset: 0, maxUtilization: 0, pendingDollars: 0, dollars: perPoint, points: 1)
        }
        let under = AgentPoolCapacityState(reset: 0, maxUtilization: 0, pendingDollars: 0, dollars: 50, points: C.minPoints / 2)
        let odd = [measured(1), measured(4), measured(2), under]
        XCTAssertEqual(C.capacity(of: nil, among: odd), 2, accuracy: 1e-12, "never measured: the median")
        XCTAssertEqual(C.capacity(of: under, among: odd), 2, accuracy: 1e-12, "under minPoints: the median, not its own 1000")
        let even = odd + [measured(8)]
        XCTAssertEqual(C.capacity(of: nil, among: even), 4, accuracy: 1e-12, "an even count: the upper median")
        XCTAssertEqual(C.capacity(of: nil, among: [under]), 1.0, "none measured")
    }
}
