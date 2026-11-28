import XCTest
@testable import ProsperApp

/// #1258: session pins in the pool's state and state file (ccpool_proxy.py PINS, PIN_IDLE, load_pins, save_pins).
/// Times are literals; no clock is read. State files live in the row's tempDir().
final class AgentPoolPinsTests: XCTestCase {
    let t0 = 1_800_000_000.0
    let orgA = "Example Org A"
    let orgB = "Example Org B"

    private func pool() -> AgentPoolState {
        AgentPoolState(order: [orgA, orgB], accounts: [orgA: .init(id: "id-a"), orgB: .init(id: "id-b")])
    }

    /// Writes `json` as the store's file in a fresh tempDir() and returns the store directory.
    private func stateDir(_ json: String, _ label: String = #function) throws -> URL {
        let dir = tempDir(label).appendingPathComponent("ccpool", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))
        return dir
    }

    private func fileObject(_ store: AgentPoolStore) throws -> [String: Any] {
        let data = try Data(contentsOf: store.stateURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func accountsJSON() -> String {
        #""accounts": {"Example Org A": {"cooldown": {"five_hour": 1800003600}, "reset": {}}, "Example Org B": {"cooldown": {}, "reset": {"seven_day": 1800090000}}}"#
    }

    // Python: stale when now - seen > PIN_IDLE, so exactly 3600 s idle is kept and anything past it expires.
    func testPinExpiresJustPastTheIdleBoundary() {
        XCTAssertEqual(AgentPoolState.pinIdle, 3600)
        var st = pool()
        XCTAssertTrue(st.pin("sess-example-1/", to: orgA, now: t0))
        XCTAssertEqual(st.pinnedAccount("sess-example-1/", now: t0 + 3600), orgA, "exactly an hour idle is kept")
        XCTAssertEqual(st.pinnedAccount("sess-example-1/", now: t0 + 3600.5), nil, "past the hour it expires")
        XCTAssertTrue(st.pins.isEmpty, "the expired pin is dropped")
        XCTAssertEqual(st.pinnedAccount("sess-example-9/", now: t0), nil, "absent")
    }

    func testTouchRestampsAndUnpinDropsEveryPinOfAnAccount() {
        var st = pool()
        st.pin("sess-example-1/", to: orgA, now: t0)
        st.pin("sess-example-1/agent-1", to: orgA, now: t0)
        st.pin("sess-example-2/", to: orgB, now: t0)
        st.touchPin("sess-example-1/", now: t0 + 3000)
        XCTAssertEqual(st.pins["sess-example-1/"]?.seen, t0 + 3000)
        st.touchPin("sess-example-9/", now: t0 + 3000)
        XCTAssertTrue(st.pins["sess-example-9/"] == nil, "a touch never makes a pin")
        XCTAssertEqual(st.pinnedAccount("sess-example-1/", now: t0 + 5000), orgA, "the touched pin lives on")
        XCTAssertEqual(st.pinnedAccount("sess-example-1/agent-1", now: t0 + 5000), nil, "the untouched one expired")
        st.pin("sess-example-3/", to: orgA, now: t0 + 5000)
        st.pin("sess-example-2/", to: orgB, now: t0 + 5000)
        st.unpin(account: orgA)
        XCTAssertEqual(Set(st.pins.keys), ["sess-example-2/"], "no pin of the removed account is left")
        // A pin to an account that left the pool reads as nil and is dropped.
        st.pin("sess-example-4/", to: orgB, now: t0 + 5000)
        st.accounts.removeValue(forKey: orgB)
        XCTAssertEqual(st.pinnedAccount("sess-example-4/", now: t0 + 5000), nil)
        XCTAssertTrue(st.pins["sess-example-4/"] == nil)
    }

    func testPinRefusesABadKeyOrAnUnknownAccount() {
        var st = pool()
        let bad = ["", String(repeating: "k", count: 129), "has space/", "tab\there/", "del\u{7F}/", "caf\u{E9}/", "nl\n/", "\u{0}/"]
        for key in bad { XCTAssertFalse(st.pin(key, to: orgA, now: t0), "refused: \(key.count) chars") }
        XCTAssertFalse(st.pin("sess-example-1/", to: "Example Org C", now: t0), "an account not in the pool")
        XCTAssertFalse(st.pin("sess-example-1/", to: orgA, now: .nan))
        XCTAssertFalse(st.pin("sess-example-1/", to: orgA, now: -1))
        XCTAssertTrue(st.pins.isEmpty)
        XCTAssertTrue(st.pin(String(repeating: "k", count: 128), to: orgA, now: t0), "128 printable characters is the limit")
        XCTAssertTrue(st.pin("~!/sess-example-1", to: orgA, now: t0))
        XCTAssertEqual(st.pins.count, 2)
    }

    // Rule chosen: a stamp after now (the clock went back), negative or not finite becomes now, so the pin
    // expires an hour after the new now: never early, never forever (Python keeps it until the clock catches up).
    func testClockBackwardsExpiresNothingEarlyAndKeepsNothingForever() {
        var st = pool()
        st.pin("sess-example-1/", to: orgA, now: t0)
        let back = t0 - 30 * 86400
        XCTAssertEqual(st.pinnedAccount("sess-example-1/", now: back), orgA, "the clock going back expires nothing")
        XCTAssertEqual(st.pins["sess-example-1/"]?.seen, back, "the stamp is pulled back to now")
        XCTAssertEqual(st.pinnedAccount("sess-example-1/", now: back + 3601), nil, "an hour after the new now it is gone")

        var odd = pool()
        odd.pins = ["f/": .init(account: orgA, seen: t0 + 2 * 86400), "i/": .init(account: orgA, seen: .infinity),
                    "n/": .init(account: orgA, seen: .nan), "m/": .init(account: orgB, seen: -5)]
        odd.expirePins(now: t0)
        XCTAssertEqual(odd.pins.count, 4, "every odd stamp is kept")
        XCTAssertTrue(odd.pins.values.allSatisfy { $0.seen == t0 }, "and treated as now")
        odd.expirePins(now: t0 + 3601)
        XCTAssertTrue(odd.pins.isEmpty, "a future stamp is not kept as given")
        var keep = pool()
        keep.pins = ["f/": .init(account: orgA, seen: t0)]
        keep.expirePins(now: .nan)
        XCTAssertEqual(keep.pins.count, 1, "a non-finite now changes nothing and does not trap")
    }

    func testPinsAreCappedOldestFirst() {
        var st = pool()
        for i in 0...AgentPoolState.pinCap {
            st.pin("sess-example-\(i)/", to: i % 2 == 0 ? orgA : orgB, now: t0 + Double(i))
        }
        XCTAssertEqual(st.pins.count, 512)
        XCTAssertTrue(st.pins["sess-example-0/"] == nil, "the oldest went first")
        XCTAssertTrue(st.pins["sess-example-1/"] != nil)
        XCTAssertTrue(st.pins["sess-example-512/"] != nil, "the newest is kept")
    }

    // Python writes "pins": {key: account} (save_pins); the native store keeps it through a read and a write.
    func testReferenceShapedFileKeepsItsPinsThroughTheStore() throws {
        let json = """
            {"current": "Example Org A", \(accountsJSON()),
             "pins": {"sess-example-1/": "Example Org A", "sess-example-1/agent-1": "Example Org A", "sess-example-2/": "Example Org B"}}
            """
        let dir = try stateDir(json)
        let store = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
        XCTAssertFalse(store.unreadable)
        let want = ["sess-example-1/": orgA, "sess-example-1/agent-1": orgA, "sess-example-2/": orgB]
        XCTAssertEqual(store.snapshot.pins.mapValues(\.account), want)
        XCTAssertTrue(store.snapshot.pins.values.allSatisfy { $0.seen == t0 }, "stamped with the load time (Python load_pins)")

        store.mutate { $0.pin("sess-example-3/", to: orgB, now: t0) }
        let obj = try fileObject(store)
        var saved = want
        saved["sess-example-3/"] = orgB
        XCTAssertEqual(obj["pins"] as? [String: String], saved, "written in Python's shape")
        XCTAssertEqual(obj["current"] as? String, orgA)
        let accounts = try XCTUnwrap(obj["accounts"] as? [String: [String: Any]])
        XCTAssertEqual(accounts[orgA]?["cooldown"] as? [String: Int], ["five_hour": 1_800_003_600])
        XCTAssertEqual(accounts[orgB]?["reset"] as? [String: Int], ["seven_day": 1_800_090_000])

        let reloaded = AgentPoolStore(directory: dir, clock: { 1_800_000_010 })
        XCTAssertEqual(reloaded.snapshot.pins.mapValues(\.account), saved, "the pins survive a native write and read")
        XCTAssertTrue(reloaded.snapshot.pins.values.allSatisfy { $0.seen == t0 + 10 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"])
    }

    // Outside data: a bad pins value or entry is skipped; the rest of the file loads and it is never moved aside.
    func testBadPinsValuesNeverFailTheLoad() throws {
        let long = String(repeating: "k", count: 129)
        let values = ["5", "\"Example Org A\"", "[\"sess-example-1/\"]", "null", "true", "{\"sess-example-1/\": [1]}"]
        for value in values {
            let dir = try stateDir("{\"current\": \"Example Org B\", \(accountsJSON()), \"pins\": \(value)}", "bad\(value.count)")
            let store = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
            XCTAssertFalse(store.unreadable, value)
            XCTAssertEqual(store.snapshot.accounts.count, 2, value)
            XCTAssertEqual(store.snapshot.current, orgB, value)
            XCTAssertTrue(store.snapshot.pins.isEmpty, value)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"], "never marked corrupt: \(value)")
        }
        let mixed = """
            {\(accountsJSON()), "pins": {"sess-example-1/": 7, "has space/": "Example Org A", "": "Example Org A",
             "\(long)": "Example Org A", "caf\\u00e9/": "Example Org A", "ctl\\u0001/": "Example Org A",
             "sess-example-2/": "Example Org C", "sess-example-3/": {"account": "Example Org A"}, "sess-example-4/": null,
             "sess-example-5/": "Example Org B"}}
            """
        let dir = try stateDir(mixed)
        let store = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
        XCTAssertFalse(store.unreadable)
        XCTAssertEqual(store.snapshot.accounts.count, 2)
        XCTAssertEqual(store.snapshot.pins.mapValues(\.account), ["sess-example-5/": orgB],
                       "only the good entry is kept; a pin to a missing account is skipped")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["state.json"])
    }

    func testLoadKeepsAtMost512Pins() throws {
        let entries = (0..<600).map { String(format: "\"sess-example-%03ld/\": \"Example Org A\"", $0) }.joined(separator: ", ")
        let dir = try stateDir("{\(accountsJSON()), \"pins\": {\(entries)}}")
        let store = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
        XCTAssertEqual(store.snapshot.pins.count, 512)
        // All loaded stamps are equal, so the tie goes by key: the smallest keys are dropped.
        XCTAssertTrue(store.snapshot.pins["sess-example-087/"] == nil)
        XCTAssertTrue(store.snapshot.pins["sess-example-088/"] != nil)
        XCTAssertTrue(store.snapshot.pins["sess-example-599/"] != nil)
    }

    // A file written before this change has no "pins": it loads with none, and a save writes no key and
    // changes none of the others beyond the change made.
    func testPreChangeNativeFileLoadsWithNoPinsAndKeepsItsShape() throws {
        let json = """
            {
              "accounts" : {
                "Example Org A" : {"cooldown" : {"five_hour" : 1800003600}, "held" : 1800003600, "id" : "id-a", "reset" : {}},
                "Example Org B" : {"cooldown" : {}, "id" : "id-b", "reset" : {"seven_day" : 1800090000}}
              },
              "current" : "Example Org A",
              "order" : ["Example Org A", "Example Org B"]
            }
            """
        let dir = try stateDir(json)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let store = AgentPoolStore(directory: dir, clock: { 1_800_000_000 })
        XCTAssertTrue(store.snapshot.pins.isEmpty)
        store.mutate { $0.order = [orgB, orgA] }   // a write (#1838: was moveAccount, removed)
        let after = try fileObject(store)
        XCTAssertEqual(Set(after.keys), ["accounts", "current", "order"], "no pins key is added")
        XCTAssertEqual(after["order"] as? [String], [orgB, orgA])
        XCTAssertEqual(after["current"] as? String, orgA)
        XCTAssertEqual(after["accounts"] as? NSDictionary, before["accounts"] as? NSDictionary)
    }
}
