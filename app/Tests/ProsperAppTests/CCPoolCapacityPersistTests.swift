import XCTest
@testable import ProsperApp

// #1260 step B: the learned capacity lives in state.json as numbers by Keychain id, is read back as outside data
// (R1257-a: a bad row is dropped, never a corrupt file), and a reply that only adds pending dollars writes nothing
// (R1260-a). Store rows only (no server, no wait): the learn step is the one CCPoolConnection.learn runs inside
// store.mutate. Writes are counted through the store's writer seam, which still does the real atomic write.
// Every state file lives in the row's tempDir(); fakes only.

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// A good row: 2.00 list-price dollars over 0.25 points, window at 0.50. Binary-exact literals.
private let goodRow = #"{"dollars":2,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#
private let goodState = CCPoolCapacityState(reset: 1_900_000_000, maxUtilization: 0.5, pendingDollars: 0, dollars: 2, points: 0.25)

/// A file with two accounts, a current, an order and a pin, plus the given "capacity" text (nil: no key).
private func stateText(capacity: String?) -> String {
    #"{"accounts":{"Example Org A":{"cooldown":{},"id":"id-example-a","reset":{}},"#
        + #""Example Org B":{"cooldown":{},"id":"id-example-b","reset":{}}},"#
        + #""current":"Example Org B","order":["Example Org B","Example Org A"],"pins":{"sess-example-1/main":"Example Org A"}"#
        + (capacity.map { #","capacity":"# + $0 } ?? "") + "}"
}

final class CCPoolCapacityPersistTests: XCTestCase {
    /// 50,000 opus output tokens at 20 $/MTok = 1.00 dollar per reply.
    private let reply = CCPoolTokenUsage(output: 50_000)

    private func store(_ dir: URL, writes: Counter) -> CCPoolStore {
        CCPoolStore(directory: dir, clock: { 1_800_000_000 },
                    writer: { data, url in writes.bump(); return CCPoolStore.atomicWrite(data, url) })
    }

    /// CCPoolConnection.learn's step, for account `id`, in the window 1900000000.
    private func learn(_ s: CCPoolStore, _ id: String, util: Double) {
        let usage = reply
        s.mutate { st in
            st.capacity[id] = CCPoolCapacity.learn(st.capacity[id] ?? CCPoolCapacityState(), model: "claude-opus-5",
                                                   usage: usage, utilization: util, reset: 1_900_000_000)
        }
    }

    private func load(_ text: String, _ label: String) throws -> (store: CCPoolStore, dir: URL) {
        let dir = tempDir(label).appendingPathComponent("ccpool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("state.json"))
        return (CCPoolStore(directory: dir, clock: { 1_800_000_000 }), dir)
    }

    /// Accounts, order, current and pins read as written; the file was neither moved aside nor rewritten.
    private func checkRest(_ s: CCPoolStore, _ dir: URL, _ text: String, _ why: String) throws {
        let st = s.snapshot
        XCTAssertFalse(s.unreadable, why)
        XCTAssertEqual(st.accounts.mapValues(\.id), ["Example Org A": "id-example-a", "Example Org B": "id-example-b"], why)
        XCTAssertEqual(st.order, ["Example Org B", "Example Org A"], why)
        XCTAssertEqual(st.current, "Example Org B", why)
        XCTAssertTrue(st.pins == ["sess-example-1/main": CCPoolState.Pin(account: "Example Org A", seen: 0)], why)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"], "not corrupt: \(why)")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("state.json"), encoding: .utf8), text, why)
    }

    // MARK: The restart and the write rule

    func testRiseWritesOnceAndARestartReadsTheNumbersBack() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let writes = Counter(), hooks = Counter()
        let s = store(dir, writes: writes)
        let id = try s.addAccount(label: "Example Org A", token: "tok-example-a", secrets: CCPoolMemorySecrets())
        s.onChange = { hooks.bump() }
        learn(s, id, util: 0.25)   // a new window: counts nothing, the window is written
        learn(s, id, util: 0.25)   // 1.00 pending
        let (w, h) = (writes.value, hooks.value)
        learn(s, id, util: 0.5)    // a rise: 2.00 dollars over 0.25 points
        XCTAssertEqual(writes.value, w + 1, "a rise writes the file once")
        XCTAssertEqual(hooks.value, h + 1, "and fires the hook once")
        XCTAssertTrue(s.snapshot.capacity == [id: goodState], "\(s.snapshot.capacity)")
        let text = try String(contentsOf: s.stateURL, encoding: .utf8)
        XCTAssertFalse(text.contains("tok-") || text.contains("opus"), "numbers only")

        let again = CCPoolStore(directory: dir, clock: { 1_800_000_000 })
        XCTAssertTrue(again.snapshot.capacity == [id: goodState], "restart: \(again.snapshot.capacity)")
        XCTAssertTrue(again.snapshot == s.snapshot)
        learn(again, id, util: 0.75)   // the same window goes on after the restart: 1.00 more over 0.25 more
        XCTAssertTrue(again.snapshot.capacity == [id: CCPoolCapacityState(reset: 1_900_000_000, maxUtilization: 0.75,
                                                                         pendingDollars: 0, dollars: 3, points: 0.5)],
                      "\(again.snapshot.capacity)")
    }

    func testPendingDollarsAloneWriteNothingAndRideAlongWithTheNextWrite() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let writes = Counter(), hooks = Counter()
        let s = store(dir, writes: writes)
        let id = try s.addAccount(label: "Example Org A", token: "tok-example-a", secrets: CCPoolMemorySecrets())
        s.onChange = { hooks.bump() }
        learn(s, id, util: 0.25)
        let (w, h) = (writes.value, hooks.value)
        for _ in 0..<3 { learn(s, id, util: 0.25) }
        learn(s, id, util: 0.24)   // a wobble below the running max is pending only too
        XCTAssertEqual(writes.value, w, "no write for pending dollars")
        XCTAssertEqual(hooks.value, h, "no change hook either")
        XCTAssertEqual(s.snapshot.capacity[id]?.pendingDollars, 4, "kept in memory")
        s.mutate { $0.current = "Example Org A" }   // any other change writes, and the pending amount rides along
        XCTAssertEqual(writes.value, w + 1)
        XCTAssertEqual(CCPoolStore(directory: dir, clock: { 1_800_000_000 }).snapshot.capacity[id]?.pendingDollars, 4)
    }

    func testRemovedAccountsRowLeavesWithTheNextWrite() throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        let s = store(dir, writes: Counter())
        let secrets = CCPoolMemorySecrets()
        let a = try s.addAccount(label: "Example Org A", token: "tok-example-a", secrets: secrets)
        let b = try s.addAccount(label: "Example Org B", token: "tok-example-b", secrets: secrets)
        learn(s, a, util: 0.25)
        learn(s, b, util: 0.25)
        func savedIDs() throws -> Set<String>? {
            let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: s.stateURL)) as? [String: Any]
            return (obj?["capacity"] as? [String: Any]).map { Set($0.keys) }
        }
        XCTAssertEqual(try savedIDs(), [a, b])
        try s.removeAccount(label: "Example Org A", secrets: secrets)
        XCTAssertEqual(try savedIDs(), [b], "the removed account's numbers are not written")
    }

    // MARK: The decode check (R1257-a)

    func testBadRowsAreDroppedAndTheRestReadsAsBefore() throws {
        let bad: [(String, String)] = [
            ("a string", #"{"dollars":"2","maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#),
            ("a bool", #"{"dollars":true,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#),
            ("a null field", #"{"dollars":null,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#),
            ("a negative", #"{"dollars":2,"maxUtilization":0.5,"pendingDollars":0,"points":-0.25,"reset":1900000000}"#),
            ("a negative reset", #"{"dollars":2,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":-1}"#),
            ("infinity", #"{"dollars":1e999,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#),
            ("minus infinity", #"{"dollars":2,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":-1e999}"#),
            ("a total past the bound", #"{"dollars":1e13,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#),
            ("a maximum above the cap", #"{"dollars":2,"maxUtilization":10.5,"pendingDollars":0,"points":0.25,"reset":1900000000}"#),
            ("a missing field", #"{"dollars":2,"maxUtilization":0.5,"points":0.25,"reset":1900000000}"#),
            ("an extra field", #"{"dollars":2,"maxUtilization":0.5,"pendingDollars":0,"points":0.25,"reset":1900000000,"model":1}"#),
            ("a string row", #""many""#),
            ("a list row", "[2,0.5,0,0.25,1900000000]"),
            ("a null row", "null"),
        ]
        for (i, (why, row)) in bad.enumerated() {
            let text = stateText(capacity: #"{"id-example-a":"# + row + #","id-example-b":"# + goodRow + "}")
            let (s, dir) = try load(text, "badRow\(i)")
            XCTAssertTrue(s.snapshot.capacity == ["id-example-b": goodState], "\(why): \(s.snapshot.capacity)")
            try checkRest(s, dir, text, why)
        }
        // The cap itself is a valid maximum.
        let atCap = goodRow.replacingOccurrences(of: #""maxUtilization":0.5"#, with: #""maxUtilization":10"#)
        let (s, _) = try load(stateText(capacity: #"{"id-example-a":"# + atCap + "}"), "atCap")
        XCTAssertEqual(s.snapshot.capacity["id-example-a"]?.maxUtilization, 10)
    }

    func testBadMapsReadAsEmptyAndRowsOutsideThePoolAreDropped() throws {
        let cases: [(String, String?, [String: CCPoolCapacityState])] = [
            ("a file from before this step", nil, [:]),
            ("the key as a list", "[1,2]", [:]),
            ("the key as null", "null", [:]),
            ("the key as a string", #""many""#, [:]),
            ("an empty map", "{}", [:]),
            ("a row for an account not in the pool",
             #"{"id-example-c":"# + goodRow + #","id-example-a":"# + goodRow + "}", ["id-example-a": goodState]),
        ]
        for (i, (why, capacity, want)) in cases.enumerated() {
            let text = stateText(capacity: capacity)
            let (s, dir) = try load(text, "badMap\(i)")
            XCTAssertTrue(s.snapshot.capacity == want, "\(why): \(s.snapshot.capacity)")
            try checkRest(s, dir, text, why)
        }
    }

    // MARK: R1260-b

    func testNullInTheCacheWriteSplitCountsZero() {
        func read(_ split: String) -> CCPoolTokenUsage? {
            var t = CCPoolUsageTap(contentType: "application/json")
            t.feed(Data((#"{"usage":{"input_tokens":10,"cache_creation_input_tokens":400,"cache_creation":"# + split
                + #","output_tokens":5}}"#).utf8))
            return t.result()
        }
        // Python dollars(): `w5 or 0`: a null in the split is 0, not the unsplit 400.
        XCTAssertTrue(read(#"{"ephemeral_5m_input_tokens":null,"ephemeral_1h_input_tokens":100}"#)
            == CCPoolTokenUsage(input: 10, output: 5, cacheWrite5m: 0, cacheWrite1h: 100))
        // An absent key still takes the unsplit count (`cc.get(key, unsplit)`).
        XCTAssertTrue(read(#"{"ephemeral_1h_input_tokens":100}"#)
            == CCPoolTokenUsage(input: 10, output: 5, cacheWrite5m: 400, cacheWrite1h: 100))
    }
}
