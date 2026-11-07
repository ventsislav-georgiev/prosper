import Network
import os
import XCTest
@testable import ProsperApp

/// #760: 0x2d sidekickSync, the sidekick pattern shared by the Mac and the phone. Preferences
/// is the in-memory XCTest store; each test puts the two keys back.
final class SidekickSyncTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var frames: [Data] = []
        var adopts = 0
    }

    private static let keys = ["agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated"]

    override func setUp() {
        super.setUp()
        let saved = Self.keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(Self.keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Self.keys.forEach(Preferences.defaults.removeObject(forKey:))
    }

    private static func body(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    private static func decode(_ f: Data) -> (type: UInt8, json: [String: Any]) {
        let b = [UInt8](f)
        return (b.first ?? 0, (try? JSONSerialization.jsonObject(with: Data(b.dropFirst(5)))) as? [String: Any] ?? [:])
    }

    /// One request through the handler (adopt counted, not run); exactly one reply.
    private func call(_ payload: Data, file: StaticString = #filePath, line: UInt = #line)
        -> (type: UInt8, json: [String: Any], adopts: Int) {
        let box = Box(), replied = expectation(description: "reply")
        var ops = DchSidekickOps()
        ops.adopted = { box.lock.withLock { box.adopts += 1 } }
        ops.handle(payload) { f in box.lock.withLock { box.frames.append(f) }; replied.fulfill() }
        wait(for: [replied], timeout: 5)
        let (frames, adopts) = box.lock.withLock { (box.frames, box.adopts) }
        XCTAssertEqual(frames.count, 1, "one reply", file: file, line: line)
        let r = Self.decode(frames.first ?? Data())
        return (r.type, r.json, adopts)
    }

    private func assertOK(_ r: (type: UInt8, json: [String: Any], adopts: Int), _ pattern: String, _ updated: Int64,
                          adopts: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.type, DchFrame.ok, "\(r.json)", file: file, line: line)
        XCTAssertEqual(r.json["pattern"] as? String, pattern, file: file, line: line)
        XCTAssertEqual((r.json["updated"] as? NSNumber)?.int64Value, updated, file: file, line: line)
        XCTAssertEqual(r.adopts, adopts, file: file, line: line)
    }

    private func assertError(_ r: (type: UInt8, json: [String: Any], adopts: Int),
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.type, DchFrame.error, "\(r.json)", file: file, line: line)
        XCTAssertNotNil(r.json["message"] as? String, file: file, line: line)
        XCTAssertEqual(r.adopts, 0, file: file, line: line)
    }

    private func stored() -> DchSidekickOps.Value {
        .init(pattern: Preferences.agentIslandSidekickPattern, updated: Preferences.agentIslandSidekickPatternUpdated)
    }

    // MARK: - Wire

    func testFrameByteAndOps() {
        XCTAssertEqual(DchFrame.sidekickSync, 0x2d)
        XCTAssertTrue((DchFrame.machineInfo(deviceID: "i", hostname: "h", wakeId: nil)["ops"] as? [String] ?? [])
            .contains("sidekick"), "always advertised")
    }

    // MARK: - Merge (pure)

    func testMerge() {
        typealias V = DchSidekickOps.Value
        let mac = V(pattern: "-qa", updated: 100)
        XCTAssertTrue(DchSidekickOps.merge(mac: mac, phone: V(pattern: "-rev", updated: 101)) == (V(pattern: "-rev", updated: 101), true))
        XCTAssertTrue(DchSidekickOps.merge(mac: mac, phone: V(pattern: "-rev", updated: 99)) == (mac, false))
        XCTAssertTrue(DchSidekickOps.merge(mac: mac, phone: V(pattern: "-rev", updated: 100)) == (mac, false), "tie: the Mac")
        let zero = V(pattern: "", updated: 0)
        XCTAssertTrue(DchSidekickOps.merge(mac: zero, phone: V(pattern: "-x", updated: 0)) == (zero, false), "both 0: the Mac")
    }

    // MARK: - Handler

    func testPhoneNewerWinsAndIsStoredVerbatim() {
        Preferences.adoptSidekickPattern("-qa", updated: 1_000)
        assertOK(call(Self.body(["pattern": "  -(qa|rev) ", "updated": 1_730_000_000_123])), "  -(qa|rev) ", 1_730_000_000_123, adopts: 1)
        XCTAssertEqual(stored(), .init(pattern: "  -(qa|rev) ", updated: 1_730_000_000_123), "raw, and the phone's stamp")
    }

    func testMacNewerWinsWithoutAdopting() {
        Preferences.adoptSidekickPattern("-mac", updated: 2_000)
        assertOK(call(Self.body(["pattern": "-phone", "updated": 1_999])), "-mac", 2_000, adopts: 0)
        XCTAssertEqual(stored(), .init(pattern: "-mac", updated: 2_000))
    }

    func testTieKeepsTheMac() {
        Preferences.adoptSidekickPattern("-mac", updated: 2_000)
        assertOK(call(Self.body(["pattern": "-phone", "updated": 2_000])), "-mac", 2_000, adopts: 0)
        XCTAssertEqual(stored(), .init(pattern: "-mac", updated: 2_000))
    }

    func testBothNeverEditedKeepsTheMac() {
        assertOK(call(Self.body(["pattern": "-phone", "updated": 0])), "-qa", 0, adopts: 0)
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandSidekickPattern"), "nothing written")
        XCTAssertNil(Preferences.defaults.object(forKey: "agentIslandSidekickPatternUpdated"))
    }

    func testRawPatternRoundTrips() {
        assertOK(call(Self.body(["pattern": "  -qa ", "updated": 5])), "  -qa ", 5, adopts: 1)
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "  -qa ")
        // ...and back out untrimmed when the Mac wins.
        assertOK(call(Self.body(["pattern": "x", "updated": 4])), "  -qa ", 5, adopts: 0)
    }

    /// 2-byte "é": a Character or UTF-16 count would let 513 bytes through.
    func testPatternCapIs512UTF8Bytes() {
        let at = String(repeating: "é", count: 256)
        XCTAssertEqual(at.utf8.count, 512)
        assertOK(call(Self.body(["pattern": at, "updated": 7])), at, 7, adopts: 1)
        Preferences.adoptSidekickPattern("-qa", updated: 1)
        assertError(call(Self.body(["pattern": at + "a", "updated": 8])))
        XCTAssertEqual(stored(), .init(pattern: "-qa", updated: 1), "an error stores nothing")
    }

    func testMalformedRequestsAreErrors() {
        for raw in [Data(), Data("not json".utf8), Data("[]".utf8), Self.body(["updated": 9]), Self.body(["pattern": "x"]),
                    Self.body(["pattern": 1, "updated": 9]), Self.body(["pattern": "x", "updated": "9"]),
                    Self.body(["pattern": "x", "updated": true]), Self.body(["pattern": "x", "updated": 9.5]),
                    Self.body(["pattern": NSNull(), "updated": 9])] {
            assertError(call(raw))
        }
        XCTAssertEqual(stored(), .init(pattern: "-qa", updated: 0))
    }

    // MARK: - Settings edit and adopt

    func testSettingsEditStampsAndAdoptEchoDoesNot() {
        let now = Date(timeIntervalSince1970: 1_730_000_000.5)
        Preferences.editSidekickPattern("-rev", now: now)
        XCTAssertEqual(stored(), .init(pattern: "-rev", updated: 1_730_000_000_500), "an edit stamps now")
        Preferences.adoptSidekickPattern("-phone", updated: 42)
        // The open field follows the adopt and its onChange hands the same value back.
        Preferences.editSidekickPattern("-phone", now: now.addingTimeInterval(60))
        XCTAssertEqual(stored(), .init(pattern: "-phone", updated: 42), "the echo is no edit")
    }

    /// The live adopt: the Settings field's notification posts, on main, after the store holds the winner.
    /// No island is up in tests, so the default re-split touches no panel.
    @MainActor
    func testLiveAdoptPostsTheSettingsNotification() throws {
        try XCTSkipIf(AgentIslandController.shared.store != nil, "an island store is up: keep its panel untouched")
        let seen = expectation(forNotification: .sidekickPatternChangedExternally, object: nil) { _ in
            Thread.isMainThread && Preferences.agentIslandSidekickPattern == "-n"
        }
        let replied = expectation(description: "reply")
        DchSidekickOps().handle(Self.body(["pattern": "-n", "updated": 3])) { _ in replied.fulfill() }
        wait(for: [seen, replied], timeout: 5)
    }

    // MARK: - Through DchConnection

    func testConnectionReplies() {
        Preferences.adoptSidekickPattern("-mac", updated: 10)
        let queue = DispatchQueue(label: "test.dchconn.sidekick")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let box = Box(), replied = expectation(description: "reply")
        conn.sidekick.adopted = { box.lock.withLock { box.adopts += 1 } }
        conn.sendOverride = { f in box.lock.withLock { box.frames.append(f) }; replied.fulfill() }
        queue.sync { conn.handle(type: DchFrame.sidekickSync, payload: Self.body(["pattern": "-p", "updated": 11])) }
        wait(for: [replied], timeout: 5)
        let r = Self.decode(box.lock.withLock { box.frames.first ?? Data() })
        XCTAssertEqual(r.type, DchFrame.ok)
        XCTAssertEqual(r.json["pattern"] as? String, "-p")
        XCTAssertEqual(box.lock.withLock { box.adopts }, 1)
        XCTAssertEqual(stored(), .init(pattern: "-p", updated: 11))
        XCTAssertFalse(queue.sync { conn.inFlight }, "the one reply cleared inFlight")
    }
}
