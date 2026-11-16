import Network
import XCTest
@testable import ProsperApp

// #1260 step A: the usage tap reads the token counts off a relayed 200 reply (Python UsageTap, ccpool_proxy.py
// 306-351) and the end of the reply feeds CCPoolCapacity.learn, in memory only. Pure rows over literal bodies, then
// rows through a stub upstream on an ephemeral loopback port, fake secrets, a tempDir() state, the wait recorder
// installed FIRST. No row sleeps or reads a clock; no body is over 1 MiB.

private let tapReset = "1900000000"
private let tapUsage = CCPoolTokenUsage(input: 1000, output: 500, cacheRead: 2000, cacheWrite5m: 400, cacheWrite1h: 0)
/// A Messages API JSON reply. Its "A" is what the byte-changing mutant turns into "B".
private let tapJSON = Data(#"{"id":"msg_example_1","type":"message","model":"claude-opus-5","content":[{"type":"text","text":"Example Org A says hi"}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":400,"cache_read_input_tokens":2000,"output_tokens":500}}"#.utf8)
private let tapStopLine = "data: {\"type\":\"message_stop\"}\n"
/// The same usage as an event stream: input and cache counts in message_start, the final output in message_delta.
private let tapSSE = Data(("event: message_start\n"
    + "data: {\"type\":\"message_start\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"cache_creation_input_tokens\":400,\"cache_read_input_tokens\":2000,\"output_tokens\":1}}}\n\n"
    + "event: content_block_delta\n"
    + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Example Org A says hi\"}}\n\n"
    + "event: message_delta\r\n"
    + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":500}}\r\n\r\n"
    + "event: message_stop\n" + tapStopLine + "\n").utf8)

private func tap(_ body: Data, stream: Bool, chunks: [Int] = []) -> CCPoolUsageTap {
    var t = CCPoolUsageTap(contentType: stream ? "text/event-stream; charset=utf-8" : "application/json")
    var at = body.startIndex
    for cut in chunks + [body.count] where cut >= at - body.startIndex {
        t.feed(body[at..<body.startIndex + cut])
        at = body.startIndex + cut
    }
    return t
}

/// One scripted reply of the stub upstream.
struct UsageTapReply {
    var status = 200
    var contentType = "application/json"
    var util = "0.10"
    var body: Data
    /// Declare more bytes than are sent, then hang up: a cut reply.
    var cut = false
    /// Send the body whole as one chunk of a chunked reply, then hang up inside the next chunk: a transport error after the usage.
    var dropMidChunk = false
}

/// Stands in for the upstream on an ephemeral loopback port; answers each request with the next scripted reply.
final class UsageTapStub: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ccpool.test.usagetap")
    private let listener: NWListener
    private let lock = NSLock()
    private var script: [UsageTapReply] = []
    private var live: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: p)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { sem.signal() }
            if case .failed = state { sem.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func push(_ r: UsageTapReply) { lock.withLock { script.append(r) } }

    func stop() {
        listener.cancel()
        lock.withLock { live }.forEach { $0.cancel() }
    }

    private func serve(_ c: NWConnection) {
        lock.withLock { live.append(c) }
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ pending: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = pending
            if let data { buf.append(data) }
            if case .head(_, let len, let rest)? = CCPoolRequestHead.parse(buf), rest.count >= len {
                let next = self.lock.withLock { self.script.isEmpty ? nil : self.script.removeFirst() }
                let r = next ?? UsageTapReply(status: 500, body: Data())
                var head = "HTTP/1.1 \(r.status) X\r\ncontent-type: \(r.contentType)\r\n"
                head += "anthropic-ratelimit-unified-5h-status: allowed\r\n"
                head += "anthropic-ratelimit-unified-5h-utilization: \(r.util)\r\n"
                head += "anthropic-ratelimit-unified-5h-reset: \(tapReset)\r\n"
                // One reply per connection, so no attempt rides a pooled connection this stub no longer reads.
                if r.dropMidChunk {
                    head += "Connection: close\r\nTransfer-Encoding: chunked\r\n\r\n" + String(r.body.count, radix: 16) + "\r\n"
                } else {
                    head += "Connection: close\r\nContent-Length: \(r.body.count + (r.cut ? 100 : 0))\r\n\r\n"
                }
                var out = Data(head.utf8)
                out.append(r.body)
                if r.dropMidChunk {
                    // The whole chunk goes first; the hang-up inside the next chunk is a second send, after the first is out.
                    out.append(Data("\r\n".utf8))
                    c.send(content: out, completion: .contentProcessed { _ in
                        c.send(content: Data("40\r\npartial".utf8), completion: .contentProcessed { _ in c.cancel() })
                    })
                    return
                }
                c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            if done || error != nil { c.cancel(); return }
            self.read(c, buf)
        }
    }
}

final class CCPoolUsageTapTests: XCTestCase {
    // MARK: The pure tap

    func testJSONReplySplitAtEveryByteReadsTheSameUsage() {
        XCTAssertTrue(tap(tapJSON, stream: false).result() == tapUsage)
        for i in 0...tapJSON.count {
            XCTAssertTrue(tap(tapJSON, stream: false, chunks: [i]).result() == tapUsage, "split at \(i)")
        }
        XCTAssertTrue(tap(tapJSON, stream: false, chunks: Array(1..<tapJSON.count)).result() == tapUsage, "byte by byte")
    }

    func testEventStreamSplitAtEveryByteReadsTheSameUsage() {
        XCTAssertTrue(tap(tapSSE, stream: true).result() == tapUsage)
        for i in 0...tapSSE.count {
            XCTAssertTrue(tap(tapSSE, stream: true, chunks: [i]).result() == tapUsage, "split at \(i)")
        }
        XCTAssertTrue(tap(tapSSE, stream: true, chunks: Array(1..<tapSSE.count)).result() == tapUsage, "byte by byte")
    }

    func testCacheCreationSplitWinsOverTheUnsplitCount() {
        let body = Data(#"{"usage":{"input_tokens":10,"cache_creation_input_tokens":400,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":100},"output_tokens":5}}"#.utf8)
        let want = CCPoolTokenUsage(input: 10, output: 5, cacheRead: 0, cacheWrite5m: 300, cacheWrite1h: 100)
        XCTAssertTrue(tap(body, stream: false).result() == want)
    }

    func testCutReplyLearnsNothing() {
        for i in 0..<tapJSON.count {
            XCTAssertTrue(tap(Data(tapJSON.prefix(i)), stream: false).result() == nil, "JSON cut at \(i)")
        }
        // An event stream counts only once its message_stop line is whole.
        let stop = tapSSE.count - 1
        XCTAssertEqual(String(decoding: tapSSE.prefix(stop).suffix(tapStopLine.utf8.count), as: UTF8.self), tapStopLine)
        for i in 0..<stop {
            XCTAssertTrue(tap(Data(tapSSE.prefix(i)), stream: true).result() == nil, "stream cut at \(i)")
        }
        XCTAssertTrue(tap(Data(tapSSE.prefix(stop)), stream: true).result() == tapUsage)
    }

    func testMalformedRepliesLearnNothingAndTrapOnNothing() {
        let bodies = [#"{"usage":{"input_tokens":1000"#, "[1,2,3]", "null", "", #"{"usage":"many"}"#, #"{"type":"message"}"#,
                      "{\"usage\":{\"input_tokens\":\u{1}}}", "\u{FF}\u{FE}garbage"]
        for b in bodies { XCTAssertTrue(tap(Data(b.utf8), stream: false).result() == nil, b) }
        let badLine = "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":5\n" + tapStopLine
        XCTAssertTrue(tap(Data(badLine.utf8), stream: true).result() == nil, "a data line with usage that does not parse")
        // Arbitrary bytes, with and without data: prefixes and "usage", in both modes: no trap, nothing read.
        var seed: UInt32 = 12345
        var junk = Data()
        for i in 0..<20_000 {
            seed = seed &* 1_103_515_245 &+ 12345
            junk.append(UInt8(truncatingIfNeeded: seed >> 16))
            if i % 997 == 0 { junk.append(contentsOf: Data("\ndata: {\"usage\":".utf8)) }
        }
        XCTAssertTrue(tap(junk, stream: false, chunks: [7, 4000]).result() == nil)
        XCTAssertTrue(tap(junk, stream: true, chunks: [7, 4000]).result() == nil)
    }

    func testBadNumbersLearnNothing() {
        for v in ["-1", "-0.5", "1e13", "1e400", "\"100\"", "true", "{}", "[1]"] {
            let json = #"{"usage":{"input_tokens":10,"output_tokens":\#(v)}}"#
            XCTAssertTrue(tap(Data(json.utf8), stream: false).result() == nil, json)
            let sse = "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":\(v)}}\n" + tapStopLine
            XCTAssertTrue(tap(Data(sse.utf8), stream: true).result() == nil, sse)
            let split = #"{"usage":{"cache_creation":{"ephemeral_1h_input_tokens":\#(v)}}}"#
            XCTAssertTrue(tap(Data(split.utf8), stream: false).result() == nil, split)
        }
        XCTAssertTrue(CCPoolUsageTap.count(NSNumber(value: Double.nan)) == nil)
        XCTAssertTrue(CCPoolUsageTap.count(NSNumber(value: Double.infinity)) == nil)
        XCTAssertTrue(CCPoolUsageTap.count(NSNumber(value: -1)) == nil)
        XCTAssertTrue(CCPoolUsageTap.count(NSNumber(value: 1e12)) == 1e12, "the bound itself is a count")
        let nulls = #"{"usage":{"input_tokens":10,"output_tokens":null}}"#
        XCTAssertTrue(tap(Data(nulls.utf8), stream: false).result() == CCPoolTokenUsage(input: 10), "a null is skipped, as in Python")
    }

    func testBodyOrLinePastTheBoundGivesUp() {
        let usage = #""usage":{"input_tokens":1000}"#
        func json(_ size: Int) -> Data {
            let shell = #"{"pad":"","# + usage + "}"
            return Data((#"{"pad":""# + String(repeating: "x", count: size - shell.utf8.count) + #"","# + usage + "}").utf8)
        }
        let atBound = json(CCPoolUsageTap.maxBuffer)
        XCTAssertEqual(atBound.count, CCPoolUsageTap.maxBuffer)
        XCTAssertTrue(tap(atBound, stream: false, chunks: [100]).result() == CCPoolTokenUsage(input: 1000), "at the bound it reads")
        var over = tap(json(CCPoolUsageTap.maxBuffer + 1), stream: false, chunks: [100])
        XCTAssertTrue(over.dead)
        over.feed(Data("x".utf8))
        XCTAssertTrue(over.result() == nil, "one byte past the bound: gave up for good")
        let line = Data(("data: {\"pad\":\"" + String(repeating: "y", count: CCPoolUsageTap.maxBuffer) + "\"," + usage + "}\n" + tapStopLine).utf8)
        let longLine = tap(line, stream: true, chunks: [1000, 300_000])
        XCTAssertTrue(longLine.dead)
        XCTAssertTrue(longLine.result() == nil, "an event line past the bound")
    }

    // MARK: Through the proxy

    struct Rig {
        let stub: UsageTapStub
        let store: CCPoolStore
        let dir: URL
        let port: UInt16
        let id: String
        func post(_ body: Data = throttleWork) -> CCPoolClientResponse? { CCPoolTestClient.request(port: port, body: body) }
        var learned: [String: CCPoolCapacityState] { store.snapshot.capacity }
    }

    /// The wait recorder is installed FIRST, before any listener exists, and restored at teardown.
    private func rig() throws -> Rig {
        let rec = ThrottleWaitRecorder()
        let saved = CCPoolConnection.throttleWait
        CCPoolConnection.throttleWait = { s, q, go in rec.wait(s, q, go) }
        addTeardownBlock { CCPoolConnection.throttleWait = saved }
        let stub = try UsageTapStub()
        XCTAssertNotEqual(stub.port, 0)
        let dir = tempDir().appendingPathComponent("ccpool")
        let store = CCPoolStore(directory: dir)
        let secrets = CCPoolMemorySecrets()
        _ = try store.addAccount(label: "Example Org A", token: "tok-a", secrets: secrets)
        store.mutate { $0.current = "Example Org A" }
        let id = try XCTUnwrap(store.snapshot.accounts["Example Org A"]?.id)
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:\(stub.port)")!
        cfg.timeout = 10
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: ThrottleLog())
        guard case .running(let p) = service.start(), p != 0 else {
            XCTFail("proxy did not start: \(service.status)")
            throw XCTSkip("no listener")
        }
        addTeardownBlock { service.stop(); stub.stop() }
        return Rig(stub: stub, store: store, dir: dir, port: p, id: id)
    }

    /// What the pure functions give for the two replies of a row: the window starts at 0.10, then rises to 0.12.
    private var firstLearn: CCPoolCapacityState {
        CCPoolCapacity.learn(CCPoolCapacityState(), model: "claude-opus-5", usage: tapUsage, utilization: 0.10, reset: 1_900_000_000)
    }
    private var secondLearn: CCPoolCapacityState {
        CCPoolCapacity.learn(firstLearn, model: "claude-opus-5", usage: tapUsage, utilization: 0.12, reset: 1_900_000_000)
    }

    private func checkTwoReplies(_ r: Rig, _ body: Data, contentType: String) throws {
        r.stub.push(UsageTapReply(contentType: contentType, util: "0.10", body: body))
        let one = try XCTUnwrap(r.post())
        XCTAssertEqual(one.status, 200, one.text)
        XCTAssertEqual(one.body, body, "the client gets the upstream's bytes, identical")
        XCTAssertTrue(r.learned == [r.id: CCPoolCapacityState(reset: 1_900_000_000, maxUtilization: 0.10)], "a new window counts nothing")
        r.stub.push(UsageTapReply(contentType: contentType, util: "0.12", body: body))
        let two = try XCTUnwrap(r.post())
        XCTAssertEqual(two.body, body, "identical again")
        let want = secondLearn
        XCTAssertTrue(r.learned == [r.id: want], "\(r.learned)")
        // Opus list prices: 1000 x 4 + 400 x 4 x 1.25 + 2000 x 0.2 + 500 x 20 = 16400 per million.
        XCTAssertEqual(want.dollars, 0.0164, accuracy: 1e-12)
        XCTAssertEqual(want.points, 0.02, accuracy: 1e-12)
        XCTAssertEqual(want.pendingDollars, 0)
        let file = try String(contentsOf: r.dir.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertTrue(try JSONDecoder().decode(CCPoolState.self, from: Data(file.utf8)).capacity == [r.id: want], "step B: the file holds it")
    }

    func testJSONReplyBytesIdenticalAndLearnedByTheLiteralAmount() throws {
        try checkTwoReplies(try rig(), tapJSON, contentType: "application/json")
    }

    func testStreamedReplyBytesIdenticalAndLearnedByTheLiteralAmount() throws {
        try checkTwoReplies(try rig(), tapSSE, contentType: "text/event-stream")
    }

    func testCutStreamLearnsNothing() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(util: "0.10", body: tapJSON))
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertTrue(r.learned == [r.id: firstLearn])
        // The whole event stream with its message_stop arrives, then the upstream hangs up short of its length.
        r.stub.push(UsageTapReply(contentType: "text/event-stream", util: "0.12", body: tapSSE, cut: true))
        _ = r.post()
        XCTAssertTrue(r.learned == [r.id: firstLearn], "a cut reply moves nothing: \(r.learned)")
    }

    /// The cut lands on the .streaming error path (onDone with an error) while the tap holds a whole usage and its
    /// message_stop: the only thing between that result and the capacity is the `error == nil` guard.
    func testStreamDroppedMidChunkWithAWholeUsageLearnsNothing() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(util: "0.10", body: tapJSON))
        XCTAssertEqual(r.post()?.status, 200)
        XCTAssertTrue(r.learned == [r.id: CCPoolCapacityState(reset: 1_900_000_000, maxUtilization: 0.10)], "before: \(r.learned)")
        XCTAssertTrue(r.learned != [r.id: secondLearn], "the 0.12 reply would change the state if it were learned")
        r.stub.push(UsageTapReply(contentType: "text/event-stream", util: "0.12", body: tapSSE, dropMidChunk: true))
        _ = r.post()
        XCTAssertTrue(r.learned == [r.id: CCPoolCapacityState(reset: 1_900_000_000, maxUtilization: 0.10)], "after: \(r.learned)")
        XCTAssertEqual(r.learned[r.id]?.dollars, 0)
        XCTAssertEqual(r.learned[r.id]?.points, 0)
        XCTAssertEqual(r.learned[r.id]?.maxUtilization, 0.10)
    }

    func testQuotaCheckLearnsNothing() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(util: "0.10", body: tapJSON))
        let resp = try XCTUnwrap(r.post(throttleQuotaCheck))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.body, tapJSON)
        XCTAssertTrue(r.learned.isEmpty, "\(r.learned)")
    }

    func testErrorReplyLearnsNothing() throws {
        let r = try rig()
        r.stub.push(UsageTapReply(status: 400, util: "0.10", body: tapJSON))
        let resp = try XCTUnwrap(r.post())
        XCTAssertEqual(resp.status, 400)
        XCTAssertEqual(resp.body, tapJSON, "relayed as before")
        XCTAssertTrue(r.learned.isEmpty, "\(r.learned)")
    }
}
