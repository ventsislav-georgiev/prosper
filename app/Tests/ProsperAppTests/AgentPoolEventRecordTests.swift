import XCTest
@testable import ProsperApp

// #1666 (#1664 F4a): the event record writer alone. Fake labels and tokens.
// #1667 (F4b): the six emit sites through the proxy (AgentPoolEventWireTests below): a fake upstream on an ephemeral
// loopback port, fake secrets, a fixed store clock, the wait recorder installed FIRST, the store under the row's tempDir().

private let evNow = 1_800_000_000.25
/// evNow's UTC day.
private let evDay = "2027-01-15"

final class AgentPoolEventRecordTests: XCTestCase {
    private func row(_ ev: AgentPoolEventRow.Kind = .bench, acct: String? = nil, from: String? = nil, to: String? = nil,
                     claim: String? = nil, reset: Int? = nil, sess: String? = nil, t: Double = evNow) -> AgentPoolEventRow {
        AgentPoolEventRow(t: t, ev: ev, acct: acct, from: from, to: to, claim: claim, reset: reset, sess: sess)
    }

    private func text(_ row: AgentPoolEventRow) throws -> String { String(decoding: try XCTUnwrap(row.line()), as: UTF8.self) }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func sparse(_ url: URL, size: Int) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(size))
        try h.close()
    }

    // MARK: line()

    func testLineKeyOrderAndOmission() throws {
        XCTAssertEqual(try text(row(.bench, acct: "Example Org A", claim: "five_hour", reset: 1_900_000_000, sess: "s-0001")),
                       #"{"v":1,"t":1800000000.250,"ev":"bench","acct":"Example Org A","claim":"five_hour","reset":1900000000,"sess":"s-0001"}"#)
        XCTAssertEqual(try text(row(.rotate, from: "Example Org A", to: "Example Org B")),
                       #"{"v":1,"t":1800000000.250,"ev":"rotate","from":"Example Org A","to":"Example Org B"}"#)
        XCTAssertEqual(try text(row(.allBenched)), #"{"v":1,"t":1800000000.250,"ev":"all-benched"}"#)
        // Every key, in the schema's order.
        XCTAssertEqual(try text(row(.pinBack, acct: "a", from: "b", to: "c", claim: "seven_day", reset: 5, sess: "s")),
                       #"{"v":1,"t":1800000000.250,"ev":"pin-back","acct":"a","from":"b","to":"c","claim":"seven_day","reset":5,"sess":"s"}"#)
    }

    func testEveryEventWordIsFixed() {
        XCTAssertEqual(AgentPoolEventRow.Kind.allCases.map(\.rawValue).sorted(),
                       ["all-benched", "bench", "pin-back", "retire", "rotate", "throttle-move"])
    }

    func testClaimAndSessionAreWrittenOnlyWhenValid() throws {
        let line = try text(row(.bench, acct: "a", claim: "Bearer tok-example-1", sess: "s 0001"))
        XCTAssertEqual(line, #"{"v":1,"t":1800000000.250,"ev":"bench","acct":"a"}"#)
        let long = String(repeating: "k", count: AgentPoolState.pinKeyMax + 1)
        XCTAssertFalse(try text(row(sess: long)).contains("sess"))
    }

    func testRowTimeIsBelowYear9999() {
        XCTAssertNotNil(row(t: 253402300799).line())
        XCTAssertTrue(row(t: 253402300800).line() == nil)
        XCTAssertTrue(row(t: -1).line() == nil)
        XCTAssertTrue(row(t: .nan).line() == nil)
    }

    func testNoTokenShapedStringOrBodyByteReachesTheLine() throws {
        // The row type has no field for a token, header or body: what a caller puts in a fixed-word slot is dropped.
        let line = try text(row(.rotate, acct: "Example Org A", from: "Example Org A", to: "Example Org B",
                                claim: "tok-example-1 body-byte-example", reset: 1, sess: "client-secret-example\n"))
        for never in ["tok-example", "body-byte-example", "client-secret-example", "Bearer", "sk-"] {
            XCTAssertFalse(line.contains(never), never)
        }
        XCTAssertFalse(line.contains("\n"))
    }

    // MARK: Name rule

    func testNameRuleMatchesOnlyEventsDayFiles() {
        XCTAssertTrue(AgentPoolEventRecord.isOwnName("events-2027-01-15.jsonl"))
        for n in ["events-2027-01-15.jsonl.bak", "events-2027-01-15.json", "Events-2027-01-15.jsonl", "events-2027-1-15.jsonl",
                  "xevents-2027-01-15.jsonl", "usage-2027-01-15.jsonl", "events-2027-01-1a.jsonl", "events-2027_01-15.jsonl",
                  "events-2027-01-15.jsonl\n", "events-.jsonl", ""] {
            XCTAssertFalse(AgentPoolEventRecord.isOwnName(n), n)
        }
    }

    // MARK: Files

    func testFileModeIs0600AndFolderIs0700() throws {
        let dir = tempDir().appendingPathComponent("events")
        let w = AgentPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(row(.rotate, from: "a", to: "b"))
        w.flush()
        let file = dir.appendingPathComponent("events-\(evDay).jsonl")
        let d = try FileManager.default.attributesOfItem(atPath: dir.path)
        let f = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((d[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((f[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), try text(row(.rotate, from: "a", to: "b")) + "\n")
    }

    func testSymlinkedNameIsNeverWritten() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.deletingLastPathComponent().appendingPathComponent("elsewhere.txt")
        try Data("keep\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("events-\(evDay).jsonl"), withDestinationURL: target)
        let log = ThrottleLog()
        let w = AgentPoolEventRecord(directory: dir, logger: log)
        w.add(row(.bench, acct: "a", claim: "five_hour"))
        w.stop()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
        XCTAssertEqual(log.lines.filter { $0.contains("event record") }, ["-: event record could not be opened; 1 row(s) dropped"])
    }

    func testSixtyFourthRowFlushesWithoutTheTimer() throws {
        let dir = tempDir().appendingPathComponent("events")
        let w = AgentPoolEventRecord(directory: dir, logger: ThrottleLog())
        let file = dir.appendingPathComponent("events-\(evDay).jsonl")
        for _ in 0..<(AgentPoolEventRecord.flushRows - 1) { w.add(row()) }
        w.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "63 rows are still held")
        w.add(row())
        w.settle()
        let n = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
        XCTAssertEqual(n, AgentPoolEventRecord.flushRows)
    }

    // MARK: Retention and caps

    func testThirtyFiveDayRemovalTouchesOnlyOwnNames() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = ["events-2020-01-01.jsonl.bak", "Events-2020-01-01.jsonl", "events-2020-1-1.jsonl", "usage-2020-01-01.jsonl", "notes.txt"]
        for n in foreign + ["events-2026-12-10.jsonl", "events-2026-12-11.jsonl", "events-2026-12-12.jsonl", "events-2027-01-02.jsonl"] {
            try Data("x\n".utf8).write(to: dir.appendingPathComponent(n))
        }
        // A folder that carries an own name is never removed.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("events-2020-01-03.jsonl"), withIntermediateDirectories: false)
        let w = AgentPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(row())
        w.stop()
        XCTAssertEqual(names(dir), (foreign + ["events-2020-01-03.jsonl", "events-2026-12-12.jsonl", "events-2027-01-02.jsonl", "events-\(evDay).jsonl"]).sorted())
    }

    func testKeepDaysIsTheUsageConstant() {
        XCTAssertEqual(AgentPoolEventRecord.keepDays, AgentPoolUsageRecord.keepDays)
        XCTAssertEqual(AgentPoolUsageRecord.keepDays, 35)
        XCTAssertEqual(AgentPoolUsageRecord.folderMax, 512 << 20)
        XCTAssertEqual(AgentPoolEventRecord.folderMax, 512 << 20)
    }

    func testFolderCapRemovesTheOldestDayFirst() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Eight days inside the 35 kept, 64 MiB each: the folder is at its cap.
        for d in 7...14 { try sparse(dir.appendingPathComponent(String(format: "events-2027-01-%02d.jsonl", d)), size: 64 << 20) }
        let w = AgentPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(row())
        w.stop()
        XCTAssertEqual(names(dir), (8...15).map { String(format: "events-2027-01-%02d.jsonl", $0) })
    }

    func testDayCapDropsAndCountsInOneLogLine() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = try XCTUnwrap(row().line())
        let file = dir.appendingPathComponent("events-\(evDay).jsonl")
        // Room for exactly one more row and its newline.
        try sparse(file, size: AgentPoolEventRecord.dayMax - line.count - 1)
        let log = ThrottleLog()
        let w = AgentPoolEventRecord(directory: dir, logger: log)
        for _ in 0..<3 { w.add(row()) }
        w.stop()
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, AgentPoolEventRecord.dayMax)
        XCTAssertEqual(log.lines.filter { $0.contains("event record") }, ["-: event record for \(evDay) reached 16 MiB; 2 row(s) dropped"])
    }

    func testRowOverTwoKiBIsNotWritten() throws {
        let dir = tempDir().appendingPathComponent("events")
        let base = try XCTUnwrap(row(acct: "").line()).count
        let fits = row(acct: String(repeating: "a", count: AgentPoolEventRecord.rowMax - base))
        let over = row(acct: String(repeating: "b", count: AgentPoolEventRecord.rowMax - base + 1))
        XCTAssertEqual(fits.line()?.count, AgentPoolEventRecord.rowMax)
        let w = AgentPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(over)
        w.add(fits)
        w.stop()
        let t = try String(contentsOf: dir.appendingPathComponent("events-\(evDay).jsonl"), encoding: .utf8)
        XCTAssertEqual(t, try text(fits) + "\n")
    }
}

/// #1667: one fake upstream reply per token, in order; a token with nothing left answers a plain 200 without rate-limit headers.
final class EventUpstream: @unchecked Sendable {
    enum Step { case spent, full, throttle }
    static let reset = 1_800_003_600
    private let lock = NSLock()
    private var script: [String: [Step]] = [:]
    func set(_ token: String, _ steps: [Step]) { lock.withLock { script[token] = steps } }

    func reply(_ head: AgentPoolRequestHead) -> AgentPoolFakeServer.Reply {
        let token = String((head.header("authorization") ?? "").dropFirst("Bearer ".count))
        let step = lock.withLock { () -> Step? in script[token]?.isEmpty == false ? script[token]?.removeFirst() : nil }
        let body = Data(#"{"type":"message","content":[{"type":"text","text":"body-byte-example"}]}"#.utf8)
        func limit(_ status: String, _ util: String) -> [(String, String)] {
            [("5h-status", status), ("5h-utilization", util), ("5h-reset", String(Self.reset))]
                .map { ("anthropic-ratelimit-unified-\($0.0)", $0.1) } + [("content-type", "application/json")]
        }
        switch step {
        case .spent?: return .respond(429, limit("rejected", "1.0"), body)
        case .full?: return .respond(200, limit("allowed", "1.0"), body)
        case .throttle?: return .respond(429, [("content-type", "application/json")], body)
        case nil: return .respond(200, [("content-type", "application/json")], body)
        }
    }
}

final class AgentPoolEventWireTests: XCTestCase {
    let orgA = "Example Org A", orgB = "Example Org B"
    let sid = "sess-example-1"
    /// What must never reach an event line: the fake tokens, the client's credential and the upstream body.
    let never = ["tok-example", "client-token", "Bearer", "body-byte-example", "content"]

    struct Rig {
        let up: EventUpstream
        let store: AgentPoolStore
        let service: AgentPoolService
        let port: UInt16
        func post(_ sid: String? = nil) -> AgentPoolClientResponse? {
            var h = [("content-type", "application/json"), ("authorization", "Bearer client-token-should-be-replaced")]
            if let sid { h.append(("X-Claude-Code-Session-Id", sid)) }
            return AgentPoolTestClient.request(port: port, headers: h, body: throttleWork)
        }
        var file: URL { service.eventRecord.directory.appendingPathComponent("events-\(evDay).jsonl") }
        /// Flushes the writer, then the day file's lines.
        func rows() -> [String] {
            service.eventRecord.flush()
            return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    private func rig(_ labels: [String]) throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = AgentPoolConnection.throttleWait
        AgentPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { AgentPoolConnection.throttleWait = saved }
        let up = EventUpstream()
        let server = try AgentPoolFakeServer { h, _ in up.reply(h) }
        XCTAssertNotEqual(server.port, 0)
        let store = AgentPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { evNow }, logger: ThrottleLog())
        let secrets = AgentPoolMemorySecrets()
        for (i, l) in labels.enumerated() { _ = try store.addAccount(label: l, token: "tok-example-\(i)", secrets: secrets) }
        store.mutate { $0.current = labels.first }
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(server.port)")!
        cfg.timeout = 10
        let service = AgentPoolService(config: cfg, store: store, secrets: secrets, logger: ThrottleLog())
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); server.stop() }
        return Rig(up: up, store: store, service: service, port: p)
    }

    private func assertClean(_ rows: [String], file: StaticString = #filePath, line: UInt = #line) {
        for r in rows { for n in never { XCTAssertFalse(r.contains(n), "\(n) in \(r)", file: file, line: line) } }
    }

    private let lead = #"{"v":1,"t":1800000000.250,"ev":"#

    func testBenchThenRotateWritesExactlyTheseRows() throws {
        let r = try rig([orgA, orgB])
        XCTAssertEqual(r.service.eventRecord.directory, r.store.directory.appendingPathComponent("events", isDirectory: true),
                       "the events folder sits beside usage/ under the test's own store folder")
        r.up.set("tok-example-0", [.spent])
        XCTAssertEqual(r.post()?.status, 200)
        let rows = r.rows()
        XCTAssertEqual(rows, [
            lead + #""bench","acct":"Example Org A","claim":"five_hour","reset":1800003600}"#,
            lead + #""rotate","from":"Example Org A","to":"Example Org B"}"#,
        ])
        assertClean(rows)
        let d = try FileManager.default.attributesOfItem(atPath: r.service.eventRecord.directory.path)
        let f = try FileManager.default.attributesOfItem(atPath: r.file.path)
        XCTAssertEqual((d[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((f[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFullReplyWritesRetire() throws {
        let r = try rig([orgA, orgB])
        r.up.set("tok-example-0", [.full])
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertEqual(r.rows(), [lead + #""retire","acct":"Example Org A","claim":"five_hour","reset":1800003600}"#])
    }

    func testEveryAccountBenchedWritesAllBenched() throws {
        let r = try rig([orgA])
        r.up.set("tok-example-0", [.spent])
        XCTAssertEqual(r.post()?.status, 429)
        let rows = r.rows()
        XCTAssertEqual(rows, [
            lead + #""bench","acct":"Example Org A","claim":"five_hour","reset":1800003600}"#,
            lead + #""rotate","from":"Example Org A"}"#,
            lead + #""all-benched","reset":1800003600}"#,
        ])
        assertClean(rows)
    }

    func testThrottleMoveThenPinBackWritesBothWithTheSession() throws {
        let r = try rig([orgA, orgB])
        XCTAssertEqual(r.post(sid)?.status, 200, "pins the session on A")
        XCTAssertEqual(r.rows(), [], "a plain reply writes no event")
        r.up.set("tok-example-0", [.throttle, .throttle, .throttle, .throttle])
        r.up.set("tok-example-1", [.throttle])
        XCTAssertEqual(r.post(sid)?.status, 429)
        let rows = r.rows()
        XCTAssertEqual(rows, [
            lead + #""throttle-move","from":"Example Org A","to":"Example Org B","sess":"sess-example-1/"}"#,
            lead + #""pin-back","acct":"Example Org A","sess":"sess-example-1/"}"#,
        ])
        assertClean(rows)
    }
}
