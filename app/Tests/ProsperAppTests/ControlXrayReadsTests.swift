import XCTest
@testable import ProsperApp

/// #1860: xray.chapters, xray.tasks, xray.memory and xray.recap through the drawer's seams, as ControlXrayTests: XrayPanels.run
/// is a fake (never a dch), the island's store a fake. Every call goes through ControlRegistry.reply, as the channel's does.
@MainActor
final class ControlXrayReadsTests: XCTestCase {
    static let dir = "/Users/example/.dch-test"

    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _cancelled = 0
        var status: Int32 = 0
        var answer = Data()
        var hold = false
        var calls: [[String]] { lock.withLock { _calls } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { _calls.append(args) }
                let end = Date().addingTimeInterval(5)
                while lock.withLock({ hold }), Date() < end {
                    if Task.isCancelled { lock.withLock { _cancelled += 1 }; return (-1, Data()) }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                return lock.withLock { (status, answer) }
            }
        }
    }

    var fake = Run()
    let base = AgentWindowD1Tests()
    private var saved: (run: XrayPanels.Run, store: @MainActor () -> AgentIslandStore?, model: @MainActor () -> AgentWindowModel?,
                        sleep: @Sendable (Double) async -> Void, now: @Sendable () -> Date)?

    override func setUp() async throws {
        saved = (XrayPanels.run, ControlSessions.islandStore, ControlSessions.model, ControlXray.sleep, ControlXrayReads.now)
        fake = Run()
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 113, 0])
        XrayPanels.run = fake.run
        var api = base.session("api", .idle, dir: Self.dir)
        api.cwd = "/Users/example/api"
        let st = base.store([api])
        ControlSessions.islandStore = { st }
        ControlSessions.model = { nil }
    }

    override func tearDown() async throws {
        if let s = saved { (XrayPanels.run, ControlSessions.islandStore, ControlSessions.model, ControlXray.sleep, ControlXrayReads.now) = s }
        XrayPanels.probed = nil
    }

    func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerXrayReads(&r)
        return r
    }

    func call(_ cmd: String, _ args: [String: ControlJSON] = api) async -> ControlReply {
        await registry().reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    func object(_ r: ControlReply) -> [String: ControlJSON] {
        if case .object(let o) = r.result { return o }
        return [:]
    }

    func list(_ r: ControlReply, _ key: String) -> [[String: ControlJSON]] {
        guard case .array(let a)? = object(r)[key] else { return [] }
        return a.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    static let api: [String: ControlJSON] = ["session": .string("api")]
    static let all = ["xray.chapters", "xray.tasks", "xray.memory", "xray.recap"]

    static func chapters(_ n: Int) -> Data {
        let rows = (1...n).map { #"{"i":\#($0),"title":"turn \#($0)","response":"ok\#($0)","tools":"Bash 2"}"# }.joined(separator: ",")
        return Data(#"{"schema":1,"chapters":[\#(rows)]}"#.utf8)
    }

    static func tasks(_ n: Int) -> Data {
        let rows = (1...n).map { #"{"task":{"id":"t\#($0)","title":"task \#($0)","status":"pending","updated":"2026-11-01T10:00:00Z"}}"# }
        return Data((["{\"schema\":1,\"source\":\"x\"}"] + rows + [#"{"done":true,"count":\#(n),"dropped":2}"#]).joined(separator: "\n").utf8)
    }

    static func memory(_ n: Int, body: String = "short") -> Data {
        let rows = (1...n).map { #"{"memory":{"id":"m\#($0)","title":"mem \#($0)","kind":"user","scope":"project","path":"/Users/example/m.md","body":"\#(body)"}}"# }
        return Data((["{\"schema\":1}"] + rows + [#"{"done":true,"count":\#(n)}"#]).joined(separator: "\n").utf8)
    }

    static func recap(chapters: Int, refs: Int) -> Data {
        let c = (1...max(chapters, 1)).prefix(chapters).map { #"{"chapter":"a\#($0)","turn_title":"new \#($0)","at":1794304801}"# }
        let r = (1...max(refs, 1)).prefix(refs).map { #"{"key":"ticket:T-\#($0)","shape":"ticket","text":"T-\#($0)","count":\#($0)}"# }
        return Data(#"{"schema":1,"since":1794300000,"chapters":[\#(c.joined(separator: ","))],"refs":[\#(r.joined(separator: ","))]}"#.utf8)
    }

    // MARK: refusals

    /// Red without ControlXray.reader (M-noReader: the session read without the gate): no dch, or one under 1.78.0, says the
    /// gate's words; nothing runs.
    func testNoOrOldDchSaysTheGatesRefusal() async {
        XrayPanels.probed = nil
        let none = await call("xray.tasks")
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 70, 0])
        let old = await call("xray.chapters")
        XCTAssertEqual(none.error, "needs dch 1.78.0")
        XCTAssertEqual(old.error, "needs dch 1.78.0")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Red if both or neither of session/cwd pass, or a folder nobody works in is read: nothing runs.
    func testExactlyOneOfSessionOrCwdNamesALiveSession() async {
        for cmd in Self.all {
            let neither = await call(cmd, [:])
            let both = await call(cmd, ["session": .string("api"), "cwd": .string("/Users/example/api")])
            let nobody = await call(cmd, ["cwd": .string("/Users/example/other")])
            XCTAssertEqual(neither.error, ControlXray.oneTarget, cmd)
            XCTAssertEqual(both.error, ControlXray.oneTarget, cmd)
            XCTAssertEqual(nobody.error, ControlXray.noSession(in: "/Users/example/other"), cmd)
        }
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Red if the timeout is not read through ControlXray.timeout, so its range is not held (M-timeoutRange), or recap's since
    /// is not checked (M-sinceRange).
    func testTimeoutAndSinceAreRangeChecked() async {
        let slow = await call("xray.tasks", ["session": .string("api"), "timeout": .number(61)])
        let negative = await call("xray.recap", ["session": .string("api"), "since": .number(-1)])
        let huge = await call("xray.recap", ["session": .string("api"), "since": .number(1e11)])
        XCTAssertEqual(slow.error, ControlXray.badTimeout)
        XCTAssertEqual(negative.error, ControlXrayReads.badSince)
        XCTAssertEqual(huge.error, ControlXrayReads.badSince)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Red without recap's version check (M-recapGate): dch 1.112.0 knows no --since; nothing runs.
    func testRecapNeedsDch1113() async {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 112, 0])
        let r = await call("xray.recap")
        XCTAssertEqual(r.error, ControlXrayReads.recapNeeds)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: the reads

    /// Red if an argv is not the drawer's (M-argv): chapters `--xray api --json`, tasks and memory `--tasks/--memory --json`,
    /// recap `--since <epoch> --json` (the since given, floored; default 24 h before the clock).
    func testEachReadRunsTheDrawersArgv() async {
        fake.answer = Self.chapters(1)
        _ = await call("xray.chapters")
        fake.answer = Self.tasks(1)
        _ = await call("xray.tasks")
        fake.answer = Self.memory(1)
        _ = await call("xray.memory")
        fake.answer = Self.recap(chapters: 1, refs: 1)
        _ = await call("xray.recap", ["session": .string("api"), "since": .number(1794300000.9)])
        ControlXrayReads.now = { Date(timeIntervalSince1970: 1794400000) }
        _ = await call("xray.recap")
        XCTAssertEqual(fake.calls, [["--xray", "api", "--json"], ["--xray", "api", "--tasks", "--json"],
                                    ["--xray", "api", "--memory", "--json"], ["--xray", "api", "--since", "1794300000", "--json"],
                                    ["--xray", "api", "--since", "1794313600", "--json"]])
    }

    /// Red if chapters are not the parse's rows in its order (M-chapterRows), or the newest 20 are not kept (M-chapterCap).
    func testChaptersAreCappedToTheNewestRows() async {
        fake.answer = Self.chapters(3)
        let few = await call("xray.chapters")
        XCTAssertEqual(list(few, "chapters").count, 3)
        XCTAssertEqual(list(few, "chapters").first?["title"], .string("turn 1"))
        XCTAssertEqual(list(few, "chapters").first?["response"], .string("ok1"))
        XCTAssertEqual(object(few)["more"], .bool(false))
        fake.answer = Self.chapters(25)
        let many = await call("xray.chapters")
        XCTAssertEqual(list(many, "chapters").count, ControlXray.maxRows)
        XCTAssertEqual(list(many, "chapters").first?["title"], .string("turn 6"))
        XCTAssertEqual(list(many, "chapters").last?["title"], .string("turn 25"))
        XCTAssertEqual(object(many)["total"], .number(25))
        XCTAssertEqual(object(many)["more"], .bool(true))
    }

    /// Red if tasks lose the drawer's order (M-taskOrder: In progress first), the open count or the row cap (M-taskCap).
    func testTasksAreOrderedAndCapped() async {
        let lines: [String] = ["{\"schema\":1}",
                               #"{"task":{"id":"p","title":"later","status":"pending"}}"#,
                               #"{"task":{"id":"a","title":"now","status":"active"}}"#,
                               #"{"task":{"id":"d","title":"was","status":"done"}}"#,
                               #"{"done":true,"dropped":2}"#]
        fake.answer = Data(lines.joined(separator: "\n").utf8)
        let r = await call("xray.tasks")
        XCTAssertEqual(list(r, "tasks").compactMap { $0["id"] }, [.string("a"), .string("p"), .string("d")])
        XCTAssertEqual(object(r)["open"], .number(2))
        XCTAssertEqual(object(r)["dropped"], .number(2))
        fake.answer = Self.tasks(25)
        let many = await call("xray.tasks")
        XCTAssertEqual(list(many, "tasks").count, ControlXray.maxRows)
        XCTAssertEqual(object(many)["total"], .number(25))
        XCTAssertEqual(object(many)["more"], .bool(true))
        XCTAssertEqual(object(many)["partial"], .bool(false))
    }

    /// Red if a body is not cut to the snippet cap (M-bodyCap) or the raw path goes out (M-noPath).
    func testMemoryBodiesAreSnippetsAndThePathStaysHome() async {
        fake.answer = Self.memory(2, body: String(repeating: "x", count: 1000))
        let r = await call("xray.memory")
        let rows = list(r, "items")
        XCTAssertEqual(rows.count, 2)
        if case .string(let b)? = rows.first?["body"] { XCTAssertEqual(b.unicodeScalars.count, ControlXray.snippetCap) } else { XCTFail("no body") }
        XCTAssertEqual(rows.first?["cut"], .bool(true))
        XCTAssertTrue(rows.first?["path"] == nil)
        fake.answer = Self.memory(25)
        let many = await call("xray.memory")
        XCTAssertEqual(list(many, "items").count, ControlXray.maxRows)
        XCTAssertEqual(object(many)["more"], .bool(true))
    }

    /// Red if recap's rows are not the parse's (M-recapRows: refs most mentioned first).
    func testRecapRowsAreTheParsesAndCapped() async {
        fake.answer = Self.recap(chapters: 2, refs: 3)
        let r = await call("xray.recap")
        XCTAssertEqual(list(r, "chapters").count, 2)
        XCTAssertEqual(list(r, "refs").first?["text"], .string("T-3"))
        XCTAssertEqual(object(r)["since"], .number(1794300000))
        XCTAssertEqual(ControlXrayReads.recapJSON(XrayRecap(since: nil, chapters: [], refs: [], more: false, partial: true)),
                       .object(["since": .null, "chapters": .array([]), "refs": .array([]), "more": .bool(false), "partial": .bool(true)]))
    }

    /// Red if recap's refs are not capped to 20 (M-recapRefCap) or the cut is not told (M-recapRefMore). The parser keeps up
    /// to 30 (XrayRecap.maxRefs) and sends more:false for 25, so only the reply's own cap answers 20 and more:true.
    func testRecapRefsAreCappedTo20() async {
        fake.answer = Self.recap(chapters: 1, refs: 25)
        let r = await call("xray.recap")
        XCTAssertEqual(list(r, "refs").count, ControlXray.maxRows)
        XCTAssertEqual(list(r, "refs").first?["text"], .string("T-25"))
        XCTAssertEqual(list(r, "refs").last?["text"], .string("T-6"))
        XCTAssertEqual(object(r)["more"], .bool(true))
    }

    /// Red if an outside control character or bidi scalar reaches the reply (M-clean).
    func testOutsideTextIsCleaned() async {
        fake.answer = Data(#"{"schema":1,"chapters":[{"i":1,"title":"a\u0007b‮c","response":"x\u001Fy"}]}"#.utf8)
        let r = await call("xray.chapters")
        XCTAssertEqual(list(r, "chapters").first?["title"], .string("abc"))
        XCTAssertEqual(list(r, "chapters").first?["response"], .string("xy"))
    }

    // MARK: answers

    /// Red if an exit is read wrong (M-status): 4/7 host unreachable, 6 refused, over-cap too large, 1 cannot read; exit 0 with
    /// bytes that do not parse is the command's own "sent no ...".
    func testExitsAreReadAsTheDrawerReadsThem() async {
        for (status, want) in [(4, "host unreachable"), (7, "host unreachable"), (6, ControlXrayReads.refused),
                               (XrayPanels.overCap, ControlXrayReads.tooLarge), (1, ControlXrayReads.cannotRead)] {
            fake.status = status
            let r = await call("xray.tasks")
            XCTAssertEqual(r.error, want, "\(status)")
        }
        fake.status = 0
        fake.answer = Data("not json".utf8)
        let t = await call("xray.tasks"), c = await call("xray.chapters"), m = await call("xray.memory"), p = await call("xray.recap")
        XCTAssertEqual(t.error, ControlXrayReads.noTasks)
        XCTAssertEqual(c.error, ControlXrayReads.noChapters)
        XCTAssertEqual(m.error, ControlXrayReads.noMemory)
        XCTAssertEqual(p.error, ControlXrayReads.noRecap)
    }

    /// Red without the deadline (M-noDeadline: the work awaited without ControlXray.within): a read past its timeout is
    /// cancelled and the reply names the timeout.
    func testTimeoutCancelsTheReadAndSaysSo() async {
        fake.hold = true
        ControlXray.sleep = { _ in try? await Task.sleep(nanoseconds: 50_000_000) }
        let r = await call("xray.memory", ["session": .string("api"), "timeout": .number(5)])
        XCTAssertEqual(r.error, ControlXray.timedOut("xray.memory", 5))
        XCTAssertEqual(fake.cancelled, 1)
    }

    // MARK: the registry

    /// Reads (they run with the Settings switch off), awaited, and describe lists the target arguments.
    func testDescribeListsAllFourAsAwaitedReads() {
        let r = registry()
        for name in Self.all {
            XCTAssertEqual(r.commands[name]?.mutates, false, name)
            XCTAssertTrue(r.commands[name]?.runAsync != nil, name)
            XCTAssertEqual(r.commands[name]?.args["session"]?.required, false, name)
            XCTAssertEqual(r.commands[name]?.args["cwd"]?.type, "string", name)
            XCTAssertEqual(r.commands[name]?.args["timeout"]?.type, "number", name)
        }
        XCTAssertEqual(r.commands["xray.recap"]?.args["since"]?.type, "number")
    }
}
