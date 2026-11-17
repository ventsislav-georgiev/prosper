import XCTest
@testable import ProsperApp

// #1482 (#1183 R1): the usage record. Literal rows through the proxy (a UsageTapStub upstream on an ephemeral loopback
// port, fake secrets, a fixed store clock, the wait recorder installed FIRST, the record under the row's tempDir()), then
// the writer alone: the day cap, the folder cap, the 14-day removal and the row cap. No row sleeps.

private let recNow = 1_800_000_000.25
/// recNow's UTC day.
private let recDay = "2027-01-15"
private let recJSON = Data(#"{"id":"msg_example_1","type":"message","model":"claude-opus-5","content":[{"type":"text","text":"body-byte-example"}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":400,"cache_read_input_tokens":2000,"output_tokens":500}}"#.utf8)
private let recStop = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
private let recSSEHead = "event: message_start\n"
    + "data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"cache_creation_input_tokens\":400,\"cache_read_input_tokens\":2000,\"output_tokens\":1}}}\n\n"
    + "event: content_block_delta\n"
    + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"body-byte-example\"}}\n\n"
    + "event: message_delta\n"
    + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":500}}\n\n"
private let recSSE = Data((recSSEHead + recStop).utf8)
private let recCounts = #""in":1000,"out":500,"cr":2000,"cw5":400,"cw1":0"#
private let recLim = #""lim":{"five_hour":{"u":0.1,"r":1900000000,"s":"a"}}"#

final class CCPoolUsageRecordTests: XCTestCase {
    struct Rig {
        let stub: UsageTapStub
        let store: CCPoolStore
        let service: CCPoolService
        let log: ThrottleLog
        let port: UInt16
        let ids: [String]
        var file: URL { store.usageDirectory.appendingPathComponent("usage-\(recDay).jsonl") }
        func post(_ body: Data = throttleWork, headers: [(String, String)] = [("content-type", "application/json")]) -> CCPoolClientResponse? {
            CCPoolTestClient.request(port: port, headers: headers, body: body)
        }
        /// Flushes the writer, then the day file's lines.
        func rows() -> [String] {
            service.usageRecord.flush()
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }

    private func rig(accounts: [String] = ["Example Org A"]) throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        let stub = try UsageTapStub()
        XCTAssertNotEqual(stub.port, 0)
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { recNow })
        let secrets = CCPoolMemorySecrets()
        var ids: [String] = []
        for (i, label) in accounts.enumerated() {
            _ = try store.addAccount(label: label, token: "tok-example-\(i)", secrets: secrets)
            ids.append(try XCTUnwrap(store.snapshot.accounts[label]?.id))
        }
        store.mutate { $0.current = accounts.first }
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(stub.port)")!
        cfg.timeout = 10
        let log = ThrottleLog()
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); stub.stop() }
        return Rig(stub: stub, store: store, service: service, log: log, port: p, ids: ids)
    }

    private func row(_ acct: String, sess: String = "", qc: Bool = false, done: Bool = true, att: Int = 1, thr: Int = 0,
                     mv: Bool = false, routed: String = "pick", counts: Bool = true) -> String {
        "{\"v\":1,\"t\":1800000000.250,\"acct\":\"\(acct)\",\"model\":\"claude-opus-5\"\(sess),\"path\":\"messages\",\"st\":200,\"ms\":0,"
            + "\"done\":\(done),\"qc\":\(qc),\"att\":\(att),\"thr\":\(thr),\"mv\":\(mv),\"routed\":\"\(routed)\""
            + (counts ? "," + recCounts : "") + "," + recLim + "}"
    }

    // MARK: Through the proxy

    func testJSONReplyRowIsLiteralAndClientBytesIdentical() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(body: recJSON))
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.body, recJSON, "the client gets the upstream's bytes, identical, with the record on")
        XCTAssertEqual(r.rows(), [row(r.ids.first ?? "")])
        let dir = try FileManager.default.attributesOfItem(atPath: r.store.usageDirectory.path)
        let file = try FileManager.default.attributesOfItem(atPath: r.file.path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEventStreamRowIsLiteralAndClientBytesIdentical() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(contentType: "text/event-stream", body: recSSE))
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.body, recSSE)
        XCTAssertEqual(r.rows(), [row(r.ids.first ?? "")])
    }

    func testCutStreamRowIsNotDoneAndHasNoCounts() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(contentType: "text/event-stream", body: Data(recSSEHead.utf8), cut: true))
        _ = r.post()
        XCTAssertEqual(r.rows(), [row(r.ids.first ?? "", done: false, counts: false)])
    }

    /// The tap is widened for the record; learn keeps its gate (D5): a quota check is recorded, flagged, and learns nothing.
    func testQuotaCheckRowIsFlaggedWithCountsAndLearnsNothing() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(body: recJSON))
        let resp = try XCTUnwrap(r.post(throttleQuotaCheck))
        XCTAssertEqual(resp.body, recJSON)
        XCTAssertEqual(r.rows(), [row(r.ids.first ?? "", qc: true)])
        XCTAssertTrue(r.store.snapshot.capacity.isEmpty, "\(r.store.snapshot.capacity)")
    }

    /// Three same-account retries of a throughput 429 on the pinned account, then the one move: one row, by the account
    /// that served it, placed.
    func testThrottledThenMovedRowIsLiteral() throws {
        let r = try rig(accounts: ["Example Org A", "Example Org B"])
        r.store.mutate { _ = $0.pin("s-0001/", to: "Example Org A", now: recNow) }
        let busy = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"body-byte-example"}}"#.utf8)
        for _ in 0..<4 { r.stub.push(UsageTapReply(status: 429, body: busy)) }
        r.stub.push(UsageTapReply(body: recJSON))
        let resp = try XCTUnwrap(r.post(headers: [("content-type", "application/json"), ("x-claude-code-session-id", "s-0001")]))
        XCTAssertEqual(resp.status, 200, resp.text)
        XCTAssertEqual(resp.body, recJSON)
        XCTAssertEqual(r.rows(), [row(r.ids.last ?? "", sess: #","sess":"s-0001","agent":"""#, att: 5, thr: 3, mv: true, routed: "place")])
    }

    func testNoTokenLabelHeaderValueOrBodyByteReachesTheFile() throws {
        let r = try rig()
        let extra = "request-id: req-example-1\r\ncf-ray: ray-example-1\r\nanthropic-organization-id: org-example-1\r\n"
        r.stub.push(UsageTapReply(body: recJSON, extra: extra))
        let body = Data(#"{"model":"claude-opus-5","max_tokens":4096,"messages":[{"role":"user","content":"prompt-byte-example"}]}"#.utf8)
        let resp = try XCTUnwrap(r.post(body, headers: [("content-type", "application/json"),
                                                        ("authorization", "Bearer client-secret-example"),
                                                        ("x-api-key", "key-secret-example"), ("x-example", "hdr-value-example"),
                                                        ("x-claude-code-session-id", "s-0002"), ("x-claude-code-agent-id", "agent-0001")]))
        XCTAssertEqual(resp.body, recJSON)
        XCTAssertEqual(r.rows(), [row(r.ids.first ?? "", sess: #","sess":"s-0002","agent":"agent-0001""#, routed: "place")])
        let text = try String(contentsOf: r.file, encoding: .utf8)
        for never in ["tok-example", "client-secret-example", "key-secret-example", "hdr-value-example", "prompt-byte-example",
                      "body-byte-example", "req-example-1", "ray-example-1", "org-example-1", "Example Org", "application/json",
                      "Bearer"] {
            XCTAssertFalse(text.contains(never), never)
        }
    }

    // MARK: The writer alone

    private func writerRow(_ acct: String = "acct-example-1") -> CCPoolUsageRow {
        CCPoolUsageRow(t: recNow, acct: acct, model: "claude-opus-5", sess: nil, agent: nil, path: "messages", st: 200, ms: 7,
                       done: true, qc: false, att: 1, thr: 0, mv: false, routed: "pick", usage: nil, lim: [:])
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func sparse(_ url: URL, size: Int) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(size))
        try h.close()
    }

    func testDayCapDropsAndCountsInOneLogLine() throws {
        let dir = tempDir().appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = try XCTUnwrap(writerRow().line())
        let file = dir.appendingPathComponent("usage-\(recDay).jsonl")
        // Room for exactly one more row and its newline.
        try sparse(file, size: CCPoolUsageRecord.dayMax - line.count - 1)
        let log = ThrottleLog()
        let w = CCPoolUsageRecord(directory: dir, logger: log)
        for _ in 0..<3 { w.add(writerRow()) }
        w.stop()
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, CCPoolUsageRecord.dayMax)
        XCTAssertEqual(log.lines.filter { $0.contains("usage record") }, ["-: usage record for \(recDay) reached 16 MiB; 2 row(s) dropped"])
    }

    func testFolderCapRemovesTheOldestDayFirst() throws {
        let dir = tempDir().appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Eight days inside the 14 kept, 16 MiB each: the folder is at its cap.
        for d in 7...14 { try sparse(dir.appendingPathComponent(String(format: "usage-2027-01-%02d.jsonl", d)), size: 16 << 20) }
        let w = CCPoolUsageRecord(directory: dir, logger: ThrottleLog())
        w.add(writerRow())
        w.stop()
        XCTAssertEqual(names(dir), (8...15).map { String(format: "usage-2027-01-%02d.jsonl", $0) })
    }

    func testFourteenDayRemovalTouchesOnlyOwnNames() throws {
        let dir = tempDir().appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = ["usage-2020-01-01.jsonl.bak", "usage-2020-01-01.json", "Usage-2020-01-01.jsonl", "usage-2020-1-1.jsonl",
                       "xusage-2020-01-01.jsonl", "notes.txt"]
        for n in foreign + ["usage-2026-12-20.jsonl", "usage-2027-01-01.jsonl", "usage-2027-01-02.jsonl"] {
            try Data("x\n".utf8).write(to: dir.appendingPathComponent(n))
        }
        // A folder that carries an own name is never removed.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("usage-2020-01-03.jsonl"), withIntermediateDirectories: false)
        let w = CCPoolUsageRecord(directory: dir, logger: ThrottleLog())
        w.add(writerRow())
        w.stop()
        XCTAssertEqual(names(dir), (foreign + ["usage-2020-01-03.jsonl", "usage-2027-01-02.jsonl", "usage-\(recDay).jsonl"]).sorted())
    }

    func testRowOverTwoKiBIsNotWritten() throws {
        let dir = tempDir().appendingPathComponent("usage")
        let base = try XCTUnwrap(writerRow("").line()).count
        let fits = writerRow(String(repeating: "a", count: CCPoolUsageRecord.rowMax - base))
        let over = writerRow(String(repeating: "b", count: CCPoolUsageRecord.rowMax - base + 1))
        XCTAssertEqual(fits.line()?.count, CCPoolUsageRecord.rowMax)
        let w = CCPoolUsageRecord(directory: dir, logger: ThrottleLog())
        w.add(over)
        w.add(fits)
        w.stop()
        let text = try String(contentsOf: dir.appendingPathComponent("usage-\(recDay).jsonl"), encoding: .utf8)
        XCTAssertEqual(text, String(decoding: try XCTUnwrap(fits.line()), as: UTF8.self) + "\n")
    }
}
