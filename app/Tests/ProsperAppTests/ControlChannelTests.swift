import Foundation
import XCTest
@testable import ProsperApp

/// #1807: the agent control channel core: socket round trip, guards (uid, size, timeout, mode, live listener),
/// the registry and describe, and the `ctl` CLI's parsing and exit codes. Every socket lives under tempDir().
final class ControlChannelTests: XCTestCase {

    /// A started server on a temp socket (short label: sun_path is 104 bytes), stopped at teardown.
    private func startServer(_ registry: ControlRegistry = .standard(), peerUID: (@Sendable (Int32) -> uid_t?)? = nil) -> ControlServer {
        let s = ControlServer(path: tempDir("ctl").appendingPathComponent("c.sock").path, registry: registry)
        if let peerUID { s.peerUID = peerUID }
        XCTAssertTrue(s.start(), "server did not start at \(s.path)")
        addTeardownBlock { s.stop() }
        return s
    }

    /// One raw request line, sent off main (handlers hop to main, so main must stay free).
    private func send(_ path: String, _ line: Data) async -> ControlReply? {
        await Task.detached {
            guard let fd = ControlServer.connect(path) else { return nil }
            defer { Darwin.close(fd) }
            return try? JSONDecoder().decode(ControlReply.self, from: ControlCLI.exchange(fd, line))
        }.value
    }

    private func send(_ path: String, _ json: String) async -> ControlReply? { await send(path, Data((json + "\n").utf8)) }

    private func cli(_ args: [String], _ path: String) async -> ControlCLI.Outcome {
        await Task.detached { ControlCLI.run(args, socketPath: path) }.value
    }

    // MARK: - Socket

    func testPingRoundTripsOnATempSocket() async {
        let s = startServer()
        let r = await send(s.path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(r, ControlReply(ok: true, result: .string("pong"), error: nil))
    }

    func testSocketFileIsOwnerOnly0600() throws {
        let s = startServer()
        let perms = try FileManager.default.attributesOfItem(atPath: s.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testAnotherUIDIsRefusedBeforeAnyHandlerRuns() async {
        let ran = ControlCallCounter()
        var reg = ControlRegistry()
        reg.register(ControlCommand(name: "ping", summary: "p", args: [:], mutates: false) { _, _ in ran.bump(); return .string("pong") })
        let s = startServer(reg, peerUID: { _ in getuid() &+ 1 })
        let r = await send(s.path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(r?.ok, false)
        XCTAssertTrue(r?.error?.contains("refused") == true, String(describing: r))
        XCTAssertEqual(ran.value, 0)
    }

    func testAFailedPeerLookupIsRefused() async {
        let s = startServer(peerUID: { _ in nil })
        let r = await send(s.path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(r?.ok, false)
    }

    func testOversizedRequestIsRefused() async {
        let s = startServer()
        // Valid JSON once it ends, so only the cap can refuse it; 1 MiB so reading it all would take 64+ reads.
        let pad = String(repeating: "x", count: 16 * ControlServer.maxRequest)
        let r = await send(s.path, #"{"cmd":"ping","args":{"pad":""# + pad + #""}}"#)
        XCTAssertEqual(r?.ok, false)
        XCTAssertTrue(r?.error?.contains("too large") == true, String(describing: r))
        XCTAssertLessThan(s.reads, 40, "the server read past the cap")
    }

    func testARequestThatNeverEndsTimesOut() async {
        let s = startServer()
        let r: ControlReply? = await Task.detached {
            guard let fd = ControlServer.connect(s.path) else { return nil }
            defer { Darwin.close(fd) }
            ControlServer.setTimeout(fd, SO_RCVTIMEO, 10)
            var buf = [UInt8](repeating: 0, count: 4096)   // nothing sent, the write side left open
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            return try? JSONDecoder().decode(ControlReply.self, from: Data(buf.prefix(n)))
        }.value
        XCTAssertEqual(r?.error, "request timed out")
    }

    func testUnknownCommandAndBadJSONGiveErrorReplies() async {
        let s = startServer()
        let unknown = await send(s.path, #"{"cmd":"launch-rockets"}"#)
        XCTAssertEqual(unknown?.ok, false)
        XCTAssertTrue(unknown?.error?.contains("unknown command: launch-rockets") == true, String(describing: unknown))
        let bad = await send(s.path, "not json")
        XCTAssertEqual(bad?.ok, false)
        XCTAssertTrue(bad?.error?.contains("bad request") == true, String(describing: bad))
    }

    func testALiveListenerIsNotReplacedButAStaleSocketIs() async throws {
        let s = startServer()
        XCTAssertFalse(ControlServer(path: s.path).start(), "a second server took over a live socket")
        let stillThere = await send(s.path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(stillThere?.ok, true)

        // A socket file nobody listens on (a crashed app's) is replaced.
        let stale = tempDir("ctl").appendingPathComponent("c.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertEqual(ControlServer.withUnixAddr(stale, { Darwin.bind(fd, $0, $1) }), 0)
        Darwin.close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale))
        let fresh = ControlServer(path: stale)
        XCTAssertTrue(fresh.start())
        addTeardownBlock { fresh.stop() }
        let r = await send(stale, #"{"cmd":"ping"}"#)
        XCTAssertEqual(r?.ok, true)
    }

    /// Perf: one request is one connection and one read() (nothing polls before or after it).
    func testOneRequestCostsOneConnectionAndOneRead() async {
        let s = startServer()
        XCTAssertEqual(s.served, 0)
        XCTAssertEqual(s.reads, 0)
        _ = await send(s.path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(s.served, 1)
        XCTAssertLessThanOrEqual(s.reads, 2)
        XCTAssertGreaterThanOrEqual(s.reads, 1)
    }

    // MARK: - Registry

    func testDescribeListsEveryRegisteredCommandWithItsSchema() async {
        let s = startServer()
        let r = await send(s.path, #"{"cmd":"describe"}"#)
        XCTAssertEqual(r?.ok, true)
        guard case .object(let o)? = r?.result, case .array(let cmds)? = o["commands"] else { return XCTFail(String(describing: r)) }
        let names = cmds.compactMap { c -> String? in if case .object(let d) = c, case .string(let n)? = d["name"] { return n }; return nil }
        // The core four; area commands (#1818 actions.*, #1809, #1810) register beside them and pin their own schemas.
        let core = ["describe", "log", "ping", "version"]
        XCTAssertTrue(Set(core).isSubset(of: names), "\(names)")
        XCTAssertEqual(names, ControlRegistry.standard().commands.keys.sorted())
        for c in cmds {
            guard case .object(let d) = c else { return XCTFail("not an object: \(c)") }
            if case .string(let summary)? = d["summary"] { XCTAssertFalse(summary.isEmpty) } else { XCTFail("no summary: \(d)") }
            guard case .string(let n)? = d["name"], core.contains(n) else { continue }
            XCTAssertEqual(d["mutates"], .bool(false), n)
            XCTAssertEqual(d["args"], .object(["type": .string("object"), "properties": .object([:]), "required": .array([])]), n)
        }
    }

    func testVersionAnswersTheBundleVersion() async {
        let s = startServer()
        let r = await send(s.path, #"{"cmd":"version"}"#)
        guard case .object(let o)? = r?.result else { return XCTFail(String(describing: r)) }
        XCTAssertEqual(o["version"], .string(AppInfo.shortVersion))
    }

    func testHandlersRunOnMainAndArgsAreCheckedAgainstTheSchema() async {
        var reg = ControlRegistry()
        reg.register(ControlCommand(name: "pick", summary: "pick a color",
                                    args: ["color": ControlArg(type: "string", required: true, allowed: ["red", "blue"]),
                                           "count": ControlArg(type: "number")],
                                    mutates: true) { _, args in .object(["main": .bool(Thread.isMainThread), "color": args["color"] ?? .null]) })
        let s = startServer(reg)
        let ok = await send(s.path, #"{"cmd":"pick","args":{"color":"red","count":2}}"#)
        XCTAssertEqual(ok?.result, .object(["main": .bool(true), "color": .string("red")]))
        for (bad, why) in [(#"{"cmd":"pick"}"#, "missing argument 'color'"),
                           (#"{"cmd":"pick","args":{"color":"green"}}"#, "must be one of red, blue"),
                           (#"{"cmd":"pick","args":{"color":"red","count":"2"}}"#, "'count' must be number"),
                           (#"{"cmd":"pick","args":{"color":"red","shade":1}}"#, "unknown argument 'shade'")] {
            let r = await send(s.path, bad)
            XCTAssertEqual(r?.ok, false, bad)
            XCTAssertTrue(r?.error?.contains(why) == true, "\(bad) -> \(String(describing: r))")
        }
        guard case .object(let d)? = reg.describe.objectValue?["commands"].flatMap({ if case .array(let a) = $0 { return a.first } else { return nil } }) else {
            return XCTFail("describe has no command")
        }
        XCTAssertEqual(d["mutates"], .bool(true))
        XCTAssertEqual(d["args"], .object(["type": .string("object"), "required": .array([.string("color")]), "properties": .object([
            "color": .object(["type": .string("string"), "enum": .array([.string("red"), .string("blue")])]),
            "count": .object(["type": .string("number")]),
        ])]))
    }

    /// #1834: red if reply(to:) calls `run` instead of awaiting `runAsync`: the async run's answer (after a suspension;
    /// main by its type) is the reply, its error an error reply; the sync run is never called.
    func testAnAsyncCommandIsAwaitedOnMain() async {
        var reg = ControlRegistry()
        reg.register(ControlCommand(name: "wait", summary: "w", args: ["fail": ControlArg(type: "boolean")], mutates: false,
                                    run: { _, _ in .string("sync") }, runAsync: { _, args in
            try? await Task.sleep(nanoseconds: 1_000_000)
            if args["fail"] == .bool(true) { throw ControlError("no answer") }
            return .string("async")
        }))
        let ok = await reg.reply(to: Data(#"{"cmd":"wait"}"#.utf8))
        let bad = await reg.reply(to: Data(#"{"cmd":"wait","args":{"fail":true}}"#.utf8))
        XCTAssertEqual(ok.result, .string("async"))
        XCTAssertEqual(bad.error, "no answer")
    }

    // MARK: - CLI

    func testCLIParsesCommandAndJSONArgs() throws {
        let plain = try ControlCLI.parse(["ping"]).get()
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: plain), ControlRequest(cmd: "ping", args: nil))
        XCTAssertEqual(plain.last, UInt8(ascii: "\n"))
        let withArgs = try ControlCLI.parse(["pick", "--json", #"{"color":"red"}"#]).get()
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: withArgs), ControlRequest(cmd: "pick", args: ["color": .string("red")]))
        let bads: [[String]] = [[], ["--json", "{}"], ["ping", "--json"], ["ping", "extra"], ["ping", "--json", "[1]"], ["ping", "--json", "{"], [""]]
        for bad in bads {
            XCTAssertThrowsError(try ControlCLI.parse(bad).get(), "\(bad)")
        }
    }

    func testCLIExitCodes() async {
        let s = startServer()
        let ok = await cli(["ping"], s.path)
        XCTAssertEqual(ok.code, 0)
        XCTAssertEqual(ok.stdout, #"{"ok":true,"result":"pong"}"#)
        let unknown = await cli(["nope"], s.path)
        XCTAssertEqual(unknown.code, 1)
        XCTAssertTrue(unknown.stdout?.contains("unknown command") == true)
        let badArgs = await cli(["ping", "--json", #"{"x":1}"#], s.path)
        XCTAssertEqual(badArgs.code, 1)
        let usage = await cli([], s.path)
        XCTAssertEqual(usage.code, 1)
        XCTAssertEqual(usage.stderr, ControlCLI.usage)
        let down = await cli(["ping"], tempDir("ctl").appendingPathComponent("none.sock").path)
        XCTAssertEqual(down.code, 2)
        XCTAssertTrue(down.stderr?.contains("not running") == true, String(describing: down.stderr))
    }

    // MARK: - #1819 nesting bound and atomic socket replace

    /// A registry whose "echo" takes an optional array `a` and string `s`, so depth rows that pass answer ok.
    private func echoRegistry() -> ControlRegistry {
        var reg = ControlRegistry.standard()
        reg.register(ControlCommand(name: "echo", summary: "e", args: ["a": ControlArg(type: "array"), "s": ControlArg(type: "string")],
                                    mutates: false) { _, _ in .bool(true) })
        return reg
    }

    /// A request line nested exactly `depth` levels: the request object, its args object, then `depth - 2` arrays.
    private func nested(_ depth: Int) -> String {
        #"{"cmd":"echo","args":{"a":"# + String(repeating: "[", count: depth - 2) + String(repeating: "]", count: depth - 2) + "}}"
    }

    func testADeeplyNestedRequestGetsAnErrorReplyAndTheServerStillAnswers() async {
        let s = startServer(echoRegistry())
        let line = nested(10_000)
        XCTAssertLessThan(line.utf8.count, ControlServer.maxRequest, "must reach the depth check, not the size cap")
        let deep = await send(s.path, line)
        XCTAssertEqual(deep?.ok, false)
        XCTAssertEqual(deep?.error, ControlDepth.message)
        let ping = await send(s.path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(ping?.result, .string("pong"))
    }

    func testDepth32PassesAndDepth33IsRefused() async {
        XCTAssertFalse(ControlDepth.exceeds(Data(nested(32).utf8)))
        XCTAssertTrue(ControlDepth.exceeds(Data(nested(33).utf8)))
        let s = startServer(echoRegistry())
        let ok = await send(s.path, nested(32))
        XCTAssertEqual(ok?.result, .bool(true), String(describing: ok))
        let refused = await send(s.path, nested(33))
        XCTAssertEqual(refused?.error, ControlDepth.message)
    }

    func testBracketsInsideAStringDoNotCount() async {
        // The escaped quote keeps the scan inside the string; a scan that ignores escapes would count all 80 brackets.
        let text = "\\\"" + String(repeating: "[{", count: 40)  // backslash, quote, then the brackets
        let line = #"{"cmd":"echo","args":{"s":""# + text + #""}}"#
        XCTAssertFalse(ControlDepth.exceeds(Data(line.utf8)))
        XCTAssertFalse(ControlDepth.exceeds(Data(#"]]]]"#.utf8) + Data(nested(32).utf8)), "stray closers must not buy depth")
        XCTAssertTrue(ControlDepth.exceeds(Data(#"]]]]"#.utf8) + Data(nested(33).utf8)), "stray closers must not buy depth")
        let s = startServer(echoRegistry())
        let r = await send(s.path, line)
        XCTAssertEqual(r?.result, .bool(true), String(describing: r))
    }

    func testCLIRefusesADeepJSONArg() async throws {
        func args(_ depth: Int) -> String { #"{"a":"# + String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1) + "}" }
        let deep = ControlCLI.parse(["echo", "--json", args(10_000)])
        guard case .failure(let e) = deep else { return XCTFail("a 10000-deep --json was accepted") }
        XCTAssertTrue(e.message.contains("nested deeper"), e.message)
        XCTAssertThrowsError(try ControlCLI.parse(["echo", "--json", args(32)]).get())
        // 31 levels of args are 32 in the request line: the deepest the server takes.
        let line = try ControlCLI.parse(["echo", "--json", args(31)]).get()
        XCTAssertFalse(ControlDepth.exceeds(line))
        XCTAssertTrue(ControlDepth.exceeds(line, limit: ControlDepth.limit - 1))
        let s = startServer(echoRegistry())
        let out = await cli(["echo", "--json", args(31)], s.path)
        XCTAssertEqual(out.code, 0, String(describing: out))
    }

    func testTheSocketIsSwappedInListeningAndOwnerOnlyWithNoTempLeft() async throws {
        // A leftover regular file at the path (not a socket) is replaced in one rename.
        let dir = tempDir("ctl")
        let path = dir.appendingPathComponent("c.sock").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("old".utf8)))
        let s = ControlServer(path: path)
        XCTAssertTrue(s.start())
        addTeardownBlock { s.stop() }
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["c.sock"], "the temp name was left behind")
        let r = await send(path, #"{"cmd":"ping"}"#)
        XCTAssertEqual(r?.ok, true)
    }
}

private extension ControlJSON {
    var objectValue: [String: ControlJSON]? { if case .object(let o) = self { return o }; return nil }
}

private final class ControlCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
