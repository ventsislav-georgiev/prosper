import XCTest
@testable import ProsperApp

/// #1834: xray.search and xray.ref through the drawer's seams: XrayPanels.run is a fake (never a dch, no process; the
/// --requests runner falls back to it under XCTest), the island's store a fake (ControlSessions.islandStore), the
/// window's --ref cache a private XrayRefResults. Every call goes through ControlRegistry.reply, as the channel's does.
@MainActor
final class ControlXrayTests: XCTestCase {
    static let dir = "/Users/example/.dch-test"
    static let target = XrayTarget(name: "api", dir: dir)

    /// Records each call's argv and stdin; a --full argv waits until `release` (at most 5 s) or its cancel.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _stdins: [String?] = []
        private var _released = true
        private var _cancelled = 0
        var status: Int32 = 0
        var answer = Data()
        var light = Data()
        var calls: [[String]] { lock.withLock { _calls } }
        var stdins: [String?] { lock.withLock { _stdins } }
        var cancelled: Int { lock.withLock { _cancelled } }
        func hold() { lock.withLock { _released = false } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                let input = XrayPanels.stdin.get().map { String(decoding: $0, as: UTF8.self) }
                lock.withLock { _calls.append(args); _stdins.append(input) }
                if args.contains("--budget-ms") { return (0, light) }
                let end = Date().addingTimeInterval(5)
                while args.contains("--full"), !lock.withLock({ _released }), Date() < end {
                    if Task.isCancelled { lock.withLock { _cancelled += 1 }; return (-1, Data()) }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                return lock.withLock { (status, answer) }
            }
        }
    }

    var fake = Run()
    var cache: XrayRefResults!
    let base = AgentWindowD1Tests()
    private var saved: (run: XrayPanels.Run, store: @MainActor () -> AgentIslandStore?, model: @MainActor () -> AgentWindowModel?,
                        cache: @MainActor () -> XrayRefResults?, sleep: @Sendable (Double) async -> Void, light: @MainActor () -> Bool)?

    override func setUp() async throws {
        saved = (XrayPanels.run, ControlSessions.islandStore, ControlSessions.model, ControlXray.cache, ControlXray.sleep,
                 XrayPanels.lightFirst)
        fake = Run()
        let c = XrayRefResults()
        cache = c
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 113, 0])
        XrayPanels.run = fake.run
        var api = base.session("api", .idle, dir: Self.dir), web = base.session("web", .idle, dir: Self.dir)
        let box = base.session("qa", .idle, dir: "@box")
        (api.cwd, web.cwd) = ("/Users/example/api", "/Users/example/web")
        let st = base.store([api, web, box])
        ControlSessions.islandStore = { st }
        ControlSessions.model = { nil }
        ControlXray.cache = { c }
    }

    override func tearDown() async throws {
        if let s = saved {
            (XrayPanels.run, ControlSessions.islandStore, ControlSessions.model, ControlXray.cache, ControlXray.sleep,
             XrayPanels.lightFirst) = s
        }
        XrayPanels.probed = nil
        cache = nil
    }

    func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerXray(&r)
        return r
    }

    func call(_ cmd: String, _ args: [String: ControlJSON]) async -> ControlReply {
        await registry().reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    func object(_ r: ControlReply) -> [String: ControlJSON] {
        if case .object(let o)? = r.result { return o }
        return [:]
    }

    func strings(_ v: ControlJSON?, _ key: String) -> [String] {
        guard case .array(let list)? = v else { return [] }
        return list.compactMap { if case .object(let o) = $0, case .string(let s)? = o[key] { s } else { nil } }
    }

    static let api: [String: ControlJSON] = ["session": .string("api")]
    func with(_ more: [String: ControlJSON], _ base: [String: ControlJSON] = api) -> [String: ControlJSON] {
        base.merging(more) { $1 }
    }

    static let searchAnswer = Data(#"""
    {"schema":1,"sessions":[{"session":"api","hits":[{"who":"user","snippet":"… fix the login\u0007 retry","at":1794304801}]},
    {"session":"api-qa","hits":[{"who":"assistant","snippet":"retry is done"}],"more":false}],"partial":false}
    """#.utf8)

    // MARK: refusals

    /// Red without the gate check: no dch, or one under 1.78.0, says the gate's own words; nothing runs.
    /// QA n139: the CLI waits past the longest deadline a read takes, so the timeout reply reaches the agent.
    func testCLIWaitsPastTheLongestReadDeadline() {
        XCTAssertGreaterThan(ControlCLI.replyTimeout, ControlXray.maxTimeout)
    }

    func testNoOrOldDchSaysTheGatesRefusal() async {
        XrayPanels.probed = nil
        let none = await call("xray.search", with(["query": .string("login")]))
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 70, 0])
        let old = await call("xray.ref", with(["path": .string("src/a.swift")]))
        XCTAssertEqual(none.error, "needs dch 1.78.0")
        XCTAssertEqual(old.error, "needs dch 1.78.0")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Red if both or neither of session/cwd pass (M-oneTarget); an unknown session or a folder no session works in
    /// is refused with ControlSessions' words or noSession; nothing runs.
    func testExactlyOneOfSessionOrCwdNamesALiveSession() async {
        let q: [String: ControlJSON] = ["query": .string("login")]
        let neither = await call("xray.search", q)
        let both = await call("xray.search", with(["cwd": .string("/Users/example/api")]).merging(q) { $1 })
        let unknown = await call("xray.search", with(["session": .string("nope")]).merging(q) { $1 })
        let nobody = await call("xray.ref", ["cwd": .string("/Users/example/other"), "path": .string("src/a.swift")])
        XCTAssertEqual(neither.error, ControlXray.oneTarget)
        XCTAssertEqual(both.error, ControlXray.oneTarget)
        XCTAssertEqual(unknown.error, "no live session named nope (sessions.list lists them)")
        XCTAssertEqual(nobody.error, ControlXray.noSession(in: "/Users/example/other"))
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Red if cwd skips the exact match (M-cwdExact): the session working in that folder is read, a trailing "/" and
    /// all; a parent folder takes the first session working below it.
    func testCwdReadsTheSessionWorkingThere() async {
        fake.answer = Data(#"{"schema":1,"hits":[]}"#.utf8)
        _ = await call("xray.search", ["cwd": .string("/Users/example/web/"), "query": .string("login")])
        _ = await call("xray.search", ["cwd": .string("/Users/example"), "query": .string("login")])
        XCTAssertEqual(fake.calls.first?.prefix(2), ["--xray", "web"])
        XCTAssertEqual(fake.calls.last?.prefix(2), ["--xray", "api"])
        XCTAssertEqual(fake.calls.count, 2)
    }

    /// The drawer's own query rule, the ref checks and the timeout's range: nothing runs.
    func testBadQueryRefLineAndTimeoutRunNothing() async {
        let q = await call("xray.search", with(["query": .string("a")]))
        let dash = await call("xray.ref", with(["path": .string("-rf")]))
        let zero = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(0)]))
        let half = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(2.5)]))
        let long = await call("xray.ref", with(["path": .string(String(repeating: "a", count: 300))]))
        let slow = await call("xray.ref", with(["path": .string("src/a.swift"), "timeout": .number(61)]))
        let none = await call("xray.search", with(["query": .string("login"), "timeout": .number(0)]))
        XCTAssertEqual(q.error, XraySearch.badQuery)
        XCTAssertEqual(dash.error, ControlXray.badRef)
        XCTAssertEqual(zero.error, ControlXray.badLine)
        XCTAssertEqual(half.error, ControlXray.badLine)
        XCTAssertTrue(long.ok == false)
        XCTAssertEqual(slow.error, ControlXray.badTimeout)
        XCTAssertEqual(none.error, ControlXray.badTimeout)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: xray.search

    /// Red if the answer skips OutsideText (the bell stays, M-clean): one call awaits one scoped read (the text on
    /// stdin) and answers with this session's hits and the other session's group.
    func testSearchAwaitsOneScopedReadAndCleansIt() async {
        fake.answer = Self.searchAnswer
        let r = await call("xray.search", with(["query": .string("login")]))
        XCTAssertEqual(fake.calls, [["--xray", "api", "--search", "-", "--scope", "project", "--json"]])
        XCTAssertEqual(fake.stdins.first ?? nil, "login\n")
        let o = object(r)
        XCTAssertEqual(o["scope"], .string("project"))
        XCTAssertEqual(strings(o["hits"], "snippet"), ["fix the login retry"])
        XCTAssertEqual(strings(o["sessions"], "session"), ["api-qa"])
    }

    /// scope "session" asks without --scope, as the drawer does below dch 1.110.0.
    func testSearchSessionScopeAsksWithoutScope() async {
        fake.answer = Data(#"{"schema":1,"hits":[{"who":"user","snippet":"login"}]}"#.utf8)
        let r = await call("xray.search", with(["query": .string("login"), "scope": .string("session")]))
        XCTAssertEqual(fake.calls, [["--xray", "api", "--search", "-", "--json"]])
        XCTAssertEqual(object(r)["scope"], .string("session"))
        XCTAssertEqual(strings(object(r)["hits"], "snippet"), ["login"])
    }

    /// Exit 1 is the drawer's "cannot search"; a remote scoped exit 1 reads once more unscoped (the text in argv).
    func testSearchExitOneSaysTheDrawersWords() async {
        fake.status = 1
        let local = await call("xray.search", with(["query": .string("login")]))
        let remote = await call("xray.search", ["session": .string("qa"), "query": .string("login")])
        XCTAssertEqual(local.error, XraySearch.cannotSearch)
        XCTAssertEqual(remote.error, XraySearch.cannotSearch)
        XCTAssertEqual(fake.calls.count, 3)
        XCTAssertEqual(fake.calls.last, ["--xray", "box:qa", "--search", "login", "--json"])
    }

    /// Red if the reply is not capped (M-cap): 60 hits come back as maxRows with "more".
    func testSearchReplyIsCapped() {
        let hits = (0..<60).map { XraySearch.Hit(who: "user", tool: nil, at: nil, snippet: "hit \($0)") }
        let o = ControlXray.searchJSON(XraySearch(hits: hits, more: false, partial: false, why: nil), scope: "project")
        guard case .object(let d) = o, case .array(let list)? = d["hits"] else { return XCTFail("no hits") }
        XCTAssertEqual(list.count, ControlXray.maxRows)
        XCTAssertEqual(d["more"], .bool(true))
    }

    // MARK: xray.ref

    static let refStream = Data([
        #"{"schema":1,"first":{"session":"api","key":"file:src/a.swift:12","shape":"file","text":"src/a.swift:12"}}"#,
        #"{"schema":1,"definition":{"session":"api","title":"Login‮ retries","passage":"Retries twice.","rule":"D1","chapter":"f12:0"}}"#,
        #"{"schema":1,"mention":{"session":"api","chapter":"f12:0","line":"see src/a.swift:12","offset":0}}"#,
        #"{"schema":1,"done":true,"partial":false,"counts":{"session":1,"project":0,"project_sessions":0}}"#,
    ].joined(separator: "\n").utf8)

    static func key(light: Bool) -> XrayRefResults.Key {
        XrayRefResults.Key(target: target, ref: "src/a.swift:12", light: light, scope: "project")
    }

    /// Red without the window-cache lookup (M-cache): a full answer the drawer cached within 30 s answers, no read.
    func testRefFullCacheHitRunsNothing() async {
        cache.put(Self.key(light: false), Self.refStream)
        let r = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(12)]))
        XCTAssertTrue(fake.calls.isEmpty)
        let o = object(r)
        XCTAssertEqual(o["light"], .bool(false))
        XCTAssertEqual(strings(o["definitions"], "title"), ["Login retries"])
        XCTAssertEqual(strings(o["mentions"], "snippet"), ["see src/a.swift:12"])
    }

    /// One full read (the ref on stdin) answers and lands in the window's cache: the next ask reads nothing.
    func testRefFullReadIsCachedForTheNextAsk() async {
        fake.answer = Self.refStream
        let first = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(12)]))
        let again = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(12)]))
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.calls.first?.contains("--full") == true)
        XCTAssertEqual(fake.stdins.first ?? nil, "src/a.swift:12\n")
        XCTAssertEqual(object(first)["light"], .bool(false))
        XCTAssertEqual(object(again), object(first))
        XCTAssertTrue(cache.get(Self.key(light: false)) != nil)
    }

    /// Red with the light read off (M-noLight): fast runs #1824's light read alone and answers with it ("light",
    /// "more"); it is cached, and a plain ask still runs the full read (a light answer never serves a full ask). A
    /// remote session's fast ask runs no light read (K4.1): the full one.
    func testRefFastAnswersWithTheLightRead() async {
        XrayPanels.lightFirst = { true }
        (fake.light, fake.answer) = (Self.refStream, Self.refStream)
        let fast = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(12), "fast": .bool(true)]))
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.calls.first?.contains("--budget-ms") == true)
        XCTAssertEqual(object(fast)["light"], .bool(true))
        XCTAssertEqual(object(fast)["more"], .bool(true))
        XCTAssertTrue(cache.get(Self.key(light: true)) != nil)
        let full = await call("xray.ref", with(["path": .string("src/a.swift"), "line": .number(12)]))
        XCTAssertEqual(object(full)["light"], .bool(false))
        _ = await call("xray.ref", ["session": .string("qa"), "path": .string("src/a.swift"), "fast": .bool(true)])
        XCTAssertEqual(fake.calls.count, 3)
        XCTAssertTrue(fake.calls.last?.contains("--full") == true)
        XCTAssertTrue(fake.calls.last?.contains("box:qa") == true)
    }

    /// Exit 2 is the card's "not a ref"; a remote's 6 its "no X-ray", 4 "host unreachable".
    func testRefRefusalsSayTheCardsWords() async {
        fake.status = 2
        let notARef = await call("xray.ref", with(["path": .string("src/a.swift")]))
        XCTAssertEqual(notARef.error, XrayPanelModel.refNotARef)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(ControlXray.refAnswer(6, nil, remote: true, unreached: false).error, XrayPanelModel.refNoXray)
        XCTAssertEqual(ControlXray.refAnswer(4, nil, remote: true, unreached: true).error, "host unreachable")
    }

    /// Red without the deadline (M-noDeadline, it would wait the fake's 5 s and answer): a read past its timeout is
    /// cancelled (its dch SIGTERMed in the product) and the reply names the timeout.
    func testTimeoutCancelsTheReadAndSaysSo() async {
        fake.hold()
        fake.answer = Self.refStream
        ControlXray.sleep = { _ in try? await Task.sleep(nanoseconds: 50_000_000) }
        let r = await call("xray.ref", with(["path": .string("src/a.swift"), "timeout": .number(5)]))
        XCTAssertEqual(r.error, ControlXray.timedOut("xray.ref", 5))
        XCTAssertEqual(fake.cancelled, 1)
        XCTAssertTrue(cache.get(Self.key(light: false)) == nil)
    }

    // MARK: the registry

    /// Both are reads (they run with the Settings switch off), awaited, and describe lists their arguments.
    func testDescribeListsBothAsAwaitedReads() {
        let r = registry()
        for name in ["xray.search", "xray.ref"] {
            XCTAssertEqual(r.commands[name]?.mutates, false, name)
            XCTAssertTrue(r.commands[name]?.runAsync != nil, name)
            XCTAssertEqual(r.commands[name]?.args["session"]?.required, false, name)
            XCTAssertEqual(r.commands[name]?.args["timeout"]?.type, "number", name)
        }
        XCTAssertTrue(r.commands["xray.search"]?.args["query"]?.required == true)
        XCTAssertTrue(r.commands["xray.ref"]?.args["path"]?.required == true)
        XCTAssertEqual(r.commands["xray.ref"]?.args["fast"]?.type, "boolean")
    }
}

private extension Result where Failure == ControlError {
    var error: String? { if case .failure(let e) = self { e.message } else { nil } }
}
