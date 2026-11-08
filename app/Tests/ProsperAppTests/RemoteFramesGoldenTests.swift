import Darwin
import Foundation
import Network
import os.log
import XCTest
@testable import ProsperApp

/// #776: docs/protocol/golden's fixtures against a real DchSessionServer on 127.0.0.1, on a
/// kernel-picked port, so Prosper's CI holds the server to the spec any server must pass.
/// Fakes only: the list, kill and rename are recorders, the watch hub is fed by hand, and
/// attach runs a shell script that prints a repaint and echoes, never dch. Never 8771,
/// never the Tailscale address, and `onReady` is a no-op so no real dch client is swept.
final class RemoteFramesGoldenTests: XCTestCase {

    private static let golden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/protocol/golden")

    private static let rows = [
        DchListRow(name: "alpha", alias: "Alpha", activityEpoch: 1, state: "working", agents: 2),
        DchListRow(name: "beta", alias: "", activityEpoch: 2, state: "", agents: 0),
    ]

    private var server: DchSessionServer!
    private var port: UInt16 = 0
    private let ran = Recorder()

    override func setUpWithError() throws {
        let script = tempDir("golden-dch").appendingPathComponent("fake-dch")
        try "#!/bin/sh\nprintf '\\033[2J\\033[Hgolden repaint\\r\\n'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        DchCommand.dchPathOverride = script.path
        let ran = ran, rows = Self.rows
        server = DchSessionServer(bindHost: { "127.0.0.1" }, port: 0, retryBase: 60, onReady: {},
                                  allowPeer: { _ in true },
                                  configure: { c in
                                      c.listSessions = { rows }
                                      c.kill = { ran.add(["-k", $0]) }
                                      c.rename = { ran.add(["-m", $0, $1]) }
                                      c.clipboard.enabled = { false }
                                      c.commands.enabled = { false }
                                  })
        let s = server!
        s.queue.sync {
            s.watch.remoteDir = { "/golden" }
            s.watch.sidekick = { DchSidekickOps.Value(pattern: "", updated: 0) }
            s.watch.island(DchWatchHub.Cache(dir: "/golden", rows: rows))
        }
        try s.start()
        port = try XCTUnwrap(s.boundPort)
        XCTAssertNotEqual(port, 0)
        XCTAssertNotEqual(port, DchSessionServer.port, "never the live server's port")
    }

    override func tearDown() {
        server?.stop()
        _ = server?.isRunning
        server?.queue.sync {}   // closes every connection, which SIGHUPs the fake dch
        DchCommand.dchPathOverride = nil
        server = nil
        super.tearDown()
    }

    // MARK: - Golden fixtures

    func testEveryGoldenFixturePassesAgainstTheServer() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.golden, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 12, "the fixtures are read from \(Self.golden.path)")
        let ops = try handshakeOps()
        XCTAssertTrue(ops.contains("watch"), "the hub has a list, so every requires_op fixture runs")
        for file in files {
            let fx = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let id = fx["id"] as? String ?? file.lastPathComponent
            if let op = fx["requires_op"] as? String { XCTAssertTrue(ops.contains(op), "\(id) would be skipped") }
            do { try run(fx) } catch { XCTFail("\(id): \(error)") }
            for hex in fx["cleanup"] as? [String] ?? [] {
                let c = try Client(port: port)
                try c.send(Self.unhex(hex))
                _ = try c.frame()
            }
        }
        let calls = ran.all
        XCTAssertTrue(calls.contains(["-k", "golden-776-no-such-session"]), "\(calls)")
        XCTAssertTrue(calls.contains(["-m", "golden-776-no-such-session", ""]), "\(calls)")
        XCTAssertTrue(calls.contains(["-k", "golden-776"]), "the attach fixture's cleanup: \(calls)")
    }

    /// The runner dch CI uses, against the same server: it must read the fixtures as this test does.
    func testPythonRunnerPassesAgainstTheServer() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", Self.golden.appendingPathComponent("run.py").path, "127.0.0.1:\(port)", "--mutating"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let pid = p.processIdentifier
        let killer = DispatchWorkItem { if p.isRunning { Darwin.kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        killer.cancel()
        XCTAssertEqual(p.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("server=prosper proto=1.0"), text)
        XCTAssertFalse(text.contains("SKIP"), text)
        XCTAssertFalse(text.contains("FAIL"), text)
        XCTAssertTrue(text.contains("OK (0 failed)"), text)
    }

    /// The shape check rejects what it should: a wrong-typed key, a missing one, a regex miss.
    func testShapeCheckRejectsMismatches() {
        let row: [String: Any] = ["name": "string", "?state": "string~working|idle|blocked|done", "?agents": "int"]
        XCTAssertNil(Self.mismatch([row], [["name": "a", "state": "idle", "agents": 2]]))
        XCTAssertNotNil(Self.mismatch([row], [["name": "a", "state": "idler"]]))
        XCTAssertNotNil(Self.mismatch([row], [["alias": "a"]]))
        XCTAssertNotNil(Self.mismatch([row], [["name": "a", "agents": true]]))
        XCTAssertNotNil(Self.mismatch(["proto": "string~1\\.[0-9]+"], ["proto": "2.0"]))
        XCTAssertNotNil(Self.mismatch(["n": "int"], ["n": 1.5]))
        XCTAssertNil(Self.mismatch(["n": "number"], ["n": 1.5]))
    }

    // MARK: - 0x08's 1.0 keys

    func testMachineInfoCarriesServerOsNameAndProto() throws {
        let info = DchFrame.machineInfo(deviceID: "id", hostname: "Studio", wakeId: nil)
        XCTAssertEqual(info["server"] as? String, "prosper")
        XCTAssertEqual(info["name"] as? String, "Studio", "the computer name, as hostname")
        XCTAssertEqual(info["proto"] as? String, "1.0")
        XCTAssertEqual(info["os"] as? String, DchFrame.osName)
        XCTAssertNotNil(DchFrame.osName.range(of: #"^macOS [0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression), DchFrame.osName)
        // Added only: the keys an older phone reads are as before.
        XCTAssertEqual(info["device_id"] as? String, "id")
        XCTAssertEqual(info["hostname"] as? String, "Studio")
        XCTAssertEqual(info["ops"] as? [String], DchFrame.ops)
        XCTAssertNil(info["wakeId"])
    }

    /// The handshake over the wire: device_id present (the phone's decodeMachineInfo needs it), proto 1.x.
    func testMachineInfoOverTheWireIsProto1() throws {
        let c = try Client(port: port)
        try c.send(Data([0x08, 0, 0, 0, 0]))
        let (type, payload) = try c.frame()
        XCTAssertEqual(type, DchFrame.machineInfoResp)
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertFalse((info["device_id"] as? String ?? "").isEmpty)
        XCTAssertEqual((info["proto"] as? String)?.split(separator: ".").first, "1")
        XCTAssertEqual(info["server"] as? String, "prosper")
    }

    // MARK: - Peer gate and close (review round 2)

    /// The production peer gate, through the init's DEFAULT allowPeer: 127.0.0.1 is outside
    /// 100.64.0.0/10, so the connection is dropped before any frame is handled. Loopback only.
    func testDefaultPeerGateDropsANonTailscalePeer() throws {
        let gated = DchSessionServer(bindHost: { "127.0.0.1" }, port: 0, retryBase: 60, onReady: {})
        defer { gated.stop(); _ = gated.isRunning; gated.queue.sync {} }
        try gated.start()
        let p = try XCTUnwrap(gated.boundPort)
        let c = try Client(port: p)
        try? c.send(Data([0x08, 0, 0, 0, 0]))   // may already fail: the server can reset first
        XCTAssertThrowsError(try c.frame(timeout: 2), "no 0x18 for a peer outside 100.64/10") {
            XCTAssertEqual($0 as? Client.Failure, .closed)
        }
        XCTAssertTrue(try c.closed(timeout: 2))
    }

    /// Once closed, a connection reads nothing more: a valid list frame ingested after close()
    /// is neither handled nor answered.
    func testNothingIsReadAfterClose() {
        let queue = DispatchQueue(label: "test.dchconn.golden")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let sent = Recorder(), lists = Recorder()
        conn.sendOverride = { f in sent.add([f.map { String(format: "%02x", $0) }.joined()]) }
        conn.listSessions = { lists.add(["list"]); return Self.rows }
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.list, [])) }
        XCTAssertEqual(lists.all.count, 1, "the seam answers a list while open")
        XCTAssertEqual(sent.all.count, 1)
        queue.sync {
            conn.close()
            conn.ingest(DchFrame.encode(DchFrame.list, []))
        }
        XCTAssertEqual(lists.all.count, 1, "no list handled after close")
        XCTAssertEqual(sent.all.count, 1, "nothing sent after close")
    }

    // MARK: - Framing

    /// The layout: type, u32 big-endian length, payload.
    func testFrameLayoutIsTypeThenBigEndianLength() {
        XCTAssertEqual([UInt8](DchFrame.encode(0x11, [1, 2, 3])), [0x11, 0, 0, 0, 3, 1, 2, 3])
        XCTAssertEqual([UInt8](DchFrame.encode(0x10, [UInt8](repeating: 7, count: 0x0102_03)).prefix(5)), [0x10, 0, 1, 2, 3])
    }

    /// Receive guard on the wire: a length of exactly 256 MiB waits for its payload, one more
    /// answers 0x13 "frame too large" and then closes. The error goes as the final message and
    /// the cancel waits for it: an immediate cancel dropped it before #776.
    func testReceiveGuardIs256MiBOnTheWire() throws {
        XCTAssertEqual(DchFrame.maxRequestFrame, 256 << 20)
        let at = try Client(port: port)
        try at.send(Data([0x10]) + Self.be32(DchFrame.maxRequestFrame))
        XCTAssertThrowsError(try at.frame(timeout: 0.5), "a length at the guard is accepted: nothing comes back") {
            XCTAssertEqual($0 as? Client.Failure, .timeout)
        }
        let past = try Client(port: port)
        try past.send(Data([0x10]) + Self.be32(DchFrame.maxRequestFrame + 1) + Data(repeating: 0x61, count: 4096))
        let (type, payload) = try past.frame()
        XCTAssertEqual(type, DchFrame.error, "Prosper's 0x13 reaches the wire before the close")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["message"] as? String, "frame too large")
        XCTAssertTrue(try past.closed(), "then the server closes, and nothing else comes")
        XCTAssertTrue(try at.closed(timeout: 0.2) == false, "the one at the guard is still open")
    }

    /// Send limit, where the code has one: 8 MiB, the phone's maxFrame. The library reply is
    /// refused past it rather than sent (DchFrame.maxFrame also bounds clipboardList).
    func testSendLimitIs8MiBWhereTheCodeChecksIt() throws {
        XCTAssertEqual(DchFrame.maxFrame, 8 << 20)
        XCTAssertEqual(DchLibraryOps.maxReply, DchFrame.maxFrame)
        let fits = DchLibraryOps.encode(["etag": "e", "pad": String(repeating: "x", count: DchFrame.maxFrame - 64)])
        XCTAssertEqual(fits.first, DchFrame.libraryResp)
        XCTAssertLessThanOrEqual(fits.count - 5, DchFrame.maxFrame)
        let over = DchLibraryOps.encode(["etag": "e", "pad": String(repeating: "x", count: DchFrame.maxFrame)])
        XCTAssertEqual(over.first, DchFrame.error)
    }

    // MARK: - Fixture runner

    private func handshakeOps() throws -> Set<String> {
        let c = try Client(port: port)
        try c.send(Data([0x08, 0, 0, 0, 0]))
        let (_, payload) = try c.frame()
        return Set((try JSONSerialization.jsonObject(with: payload) as? [String: Any])?["ops"] as? [String] ?? [])
    }

    private struct Mismatch: Error, CustomStringConvertible { let description: String }

    private func run(_ fx: [String: Any]) throws {
        let c = try Client(port: port)
        for step in fx["steps"] as? [[String: Any]] ?? [] {
            if let hex = step["send"] as? String {
                try c.send(Self.unhex(hex))
            } else if let want = step["expect"] as? [String: Any] {
                let (type, payload) = try c.frame()
                if let why = Self.check(want, type, payload) { throw Mismatch(description: why) }
            } else if step["expect_close"] as? Bool == true {
                guard try c.closed() else { throw Mismatch(description: "the server did not close the connection") }
            }
        }
    }

    private static func check(_ want: [String: Any], _ type: UInt8, _ payload: Data) -> String? {
        guard let t = (want["type"] as? String).flatMap({ UInt8($0, radix: 16) }), t == type else {
            return "want type \(want["type"] ?? "?"), got \(String(format: "%02x", type))"
        }
        if let hex = want["payload"] as? String, payload != unhex(hex) { return "want payload \(hex), got \(payload.count) bytes" }
        if want["nonempty"] as? Bool == true, payload.isEmpty { return "want a non-empty payload" }
        if let shape = want["json"] {
            guard let v = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) else {
                return "payload is not JSON"
            }
            return mismatch(shape, v)
        }
        return nil
    }

    /// run.py's shape_ok, in Swift: nil on a match, else the first mismatch.
    static func mismatch(_ shape: Any, _ v: Any, _ path: String = "$") -> String? {
        if let s = shape as? String {
            let parts = s.split(separator: "~", maxSplits: 1).map(String.init)
            let n = v as? NSNumber, isBool = n.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            let ok: Bool
            switch parts[0] {
            case "any": ok = true
            case "string": ok = v is String
            case "bool": ok = isBool
            case "int": ok = n != nil && !isBool && !CFNumberIsFloatType(n! as CFNumber)
            case "number": ok = n != nil && !isBool
            case "object": ok = v is [String: Any]
            case "array": ok = v is [Any]
            default: return "\(path): unknown shape \(s)"
            }
            guard ok else { return "\(path): want \(parts[0]), got \(v)" }
            if parts.count == 2, let str = v as? String,
               str.range(of: "^(?:\(parts[1]))$", options: .regularExpression) == nil {
                return "\(path): \(str) does not match \(parts[1])"
            }
            return nil
        }
        if let shapes = shape as? [Any] {
            guard let arr = v as? [Any] else { return "\(path): want array" }
            for (i, e) in arr.enumerated() {
                for s in shapes { if let why = mismatch(s, e, "\(path)[\(i)]") { return why } }
            }
            return nil
        }
        if let keys = shape as? [String: Any] {
            guard let o = v as? [String: Any] else { return "\(path): want object" }
            for (k, s) in keys {
                let key = k.hasPrefix("?") ? String(k.dropFirst()) : k
                guard let value = o[key] else {
                    if k.hasPrefix("?") { continue }
                    return "\(path): missing key \(key)"
                }
                if let why = mismatch(s, value, "\(path).\(key)") { return why }
            }
            return nil
        }
        return "\(path): bad shape"
    }

    static func unhex(_ s: String) -> Data {
        let h = Array(s.filter { !$0.isWhitespace }.utf8)
        return Data(stride(from: 0, to: h.count - 1, by: 2).compactMap { UInt8(String(decoding: h[$0...$0 + 1], as: UTF8.self), radix: 16) })
    }

    static func be32(_ n: Int) -> Data {
        Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
    }
}

/// A blocking loopback client: one socket, a receive timeout, frames reassembled.
private final class Client {
    enum Failure: Error, Equatable { case connect, closed, timeout, oversize }

    private let fd: Int32
    private var buf = Data()

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard fd >= 0, ok else { Darwin.close(fd); throw Failure.connect }
    }

    deinit { Darwin.close(fd) }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                guard n > 0 else { throw Failure.closed }
                off += n
            }
        }
    }

    /// False on EOF; throws on timeout.
    private func fill(_ n: Int, timeout: TimeInterval) throws -> Bool {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while buf.count < n {
            let got = recv(fd, &chunk, chunk.count, 0)
            if got == 0 || (got < 0 && errno == ECONNRESET) { return false }
            if got < 0 { throw Failure.timeout }
            buf.append(contentsOf: chunk[0..<got])
        }
        return true
    }

    /// The next frame; every frame must be within the server's 8 MiB send limit.
    func frame(timeout: TimeInterval = 5) throws -> (UInt8, Data) {
        guard try fill(5, timeout: timeout) else { throw Failure.closed }
        let b = [UInt8](buf.prefix(5))
        let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard n <= DchFrame.maxFrame else { throw Failure.oversize }
        guard try fill(5 + n, timeout: timeout) else { throw Failure.closed }
        let payload = buf.subdata(in: buf.startIndex + 5..<buf.startIndex + 5 + n)
        buf.removeFirst(5 + n)
        return (b[0], payload)
    }

    /// True once the server closed (EOF or reset) within `timeout`, as run.py: bytes before the close are ignored.
    func closed(timeout: TimeInterval = 5) throws -> Bool {
        do {
            while try fill(buf.count + 1, timeout: timeout) {}
            return true
        } catch Failure.timeout { return false }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ c: [String]) { lock.withLock { calls.append(c) } }
    var all: [[String]] { lock.withLock { calls } }
}
