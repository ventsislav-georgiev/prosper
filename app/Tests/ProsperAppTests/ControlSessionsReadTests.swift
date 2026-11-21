import Foundation
import XCTest
@testable import ProsperApp

/// #1840: sessions.get / sessions.wait / sessions.screen / sessions.transcript. Sessions come from AgentWindowD1Tests'
/// fakes through ControlSessions' store seam; the screen read is a recorder (never a real dch); transcripts are files
/// under tempDir(). The awaited commands go through ControlRegistry.reply, as the channel's do. Seams go back after each row.
@MainActor
final class ControlSessionsReadTests: XCTestCase {
    let base = AgentWindowD1Tests()
    private var saved: (store: @MainActor () -> AgentIslandStore?, model: @MainActor () -> AgentWindowModel?,
                        screen: @Sendable (AgentSessionKey) async -> Data?, sleep: @Sendable (Double) async -> Void)?

    override func setUp() async throws {
        saved = (ControlSessions.islandStore, ControlSessions.model, ControlSessionsRead.readScreen, ControlXray.sleep)
        ControlSessions.model = { nil }
        ControlSessionsRead.resetCounts()
    }

    override func tearDown() async throws {
        if let s = saved {
            (ControlSessions.islandStore, ControlSessions.model, ControlSessionsRead.readScreen, ControlXray.sleep) = s
        }
        Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
    }

    func use(_ st: AgentIslandStore?) { ControlSessions.islandStore = { st } }

    static func call(_ cmd: String, _ args: [String: ControlJSON]) async -> ControlReply {
        var r = ControlRegistry()
        ControlRegistry.registerSessionsRead(&r)
        return await r.reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    func obj(_ j: ControlJSON?) -> [String: ControlJSON] {
        guard case .object(let o)? = j else { return [:] }
        return o
    }

    func name(_ n: String) -> [String: ControlJSON] { ["name": .string(n)] }

    func refused(_ expr: () throws -> ControlJSON, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    /// Yields until the wait has looked at the store `n` times (bounded: a broken wait fails the row, never hangs it).
    func checks(_ n: Int) async {
        for _ in 0..<2_000 where ControlSessionsRead.waitChecks < n { await Task.yield() }
        XCTAssertEqual(ControlSessionsRead.waitChecks, n)
    }

    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var n = 0, cancels = 0
        func bump() { lock.withLock { n += 1 } }
        func cancel() { lock.withLock { cancels += 1 } }
        var count: Int { lock.withLock { n } }
        var cancelled: Int { lock.withLock { cancels } }
    }

    // MARK: - sessions.get

    /// One full row: sessions.list's fields plus the status word, subagents, model, pty, PRs (label, title, the
    /// allowlisted url only), merged, shells and whether a transcript is mapped. Lookup by title works; unknown refused.
    func testGetReturnsTheFullRow() throws {
        var api = base.session("api", .blocked, alias: "API", agents: 2, path: "/Users/example/t.jsonl")
        api.cwd = "/Users/example/api"
        api.model = "opus"
        api.pty = AgentSessionPty(cols: 120, rows: 40, clients: 1)
        api.meta = DchSessionMeta(json: ["prs": ["open": [
            ["url": "https://github.com/example/api/pull/12", "repo": "example/api", "num": 12, "title": "Fix it"],
            ["url": "https://evil.example/x", "repo": "example/web", "num": 3, "title": "Other"],
        ], "merged": 4]])
        use(base.store([api, base.session("api-qa", .idle)]))
        let r = obj(try ControlSessionsRead.get(name("API")))
        XCTAssertEqual(r["name"], .string("api"))
        XCTAssertEqual(r["state"], .string("Needs input"), "sessions.list's field")
        XCTAssertEqual(r["agent"], .string("claude"))
        XCTAssertEqual(r["cwd"], .string("/Users/example/api"))
        XCTAssertEqual(r["status"], .string("needs-you"))
        XCTAssertEqual(r["subagents"], .number(2))
        XCTAssertEqual(r["model"], .string("opus"))
        XCTAssertEqual(r["effort"], .null)
        XCTAssertEqual(obj(r["pty"])["cols"], .number(120))
        XCTAssertEqual(r["merged"], .number(4))
        XCTAssertEqual(r["transcript"], .bool(true))
        guard case .array(let prs)? = r["prs"] else { return XCTFail("no prs") }
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(obj(prs.first)["url"], .string("https://github.com/example/api/pull/12"))
        XCTAssertEqual(obj(prs.first)["label"], .string("api#12"))
        XCTAssertEqual(obj(prs.last)["url"], .null, "a url off the allowlist is never handed out")
        XCTAssertEqual(obj(try ControlSessionsRead.get(name("api-qa")))["transcript"], .bool(false))
        refused({ try ControlSessionsRead.get(self.name("web")) }, "no live session named web (sessions.list lists them)")
        use(nil)
        refused({ try ControlSessionsRead.get(self.name("api")) }, ControlSessions.islandOff)
    }

    // MARK: - sessions.wait

    /// idle is idle or done; needs-you is blocked; a session no longer listed is ended (reached only for state ended).
    func testVerdictPerState() {
        let done = base.session("api", .done), blocked = base.session("api", .blocked), working = base.session("api", .working)
        XCTAssertEqual(ControlSessionsRead.verdict(done, "idle"), .object(["reached": .bool(true), "state": .string("done")]))
        XCTAssertEqual(ControlSessionsRead.verdict(base.session("api", .idle), "idle"),
                       .object(["reached": .bool(true), "state": .string("idle")]))
        XCTAssertTrue(ControlSessionsRead.verdict(blocked, "idle") == nil)
        XCTAssertTrue(ControlSessionsRead.verdict(working, "idle") == nil)
        XCTAssertEqual(ControlSessionsRead.verdict(blocked, "needs-you"), .object(["reached": .bool(true), "state": .string("needs-you")]))
        XCTAssertTrue(ControlSessionsRead.verdict(done, "needs-you") == nil)
        XCTAssertTrue(ControlSessionsRead.verdict(done, "ended") == nil)
        XCTAssertEqual(ControlSessionsRead.verdict(nil, "idle"), .object(["ended": .bool(true)]))
        XCTAssertEqual(ControlSessionsRead.verdict(nil, "ended"), .object(["reached": .bool(true), "state": .string("ended")]))
    }

    /// The wait answers on the store's own change, with one check per publish (the current list, then each change)
    /// and nothing in between: no poll, no timer.
    func testWaitAnswersOnTheStoresChange() async {
        let st = base.store([base.session("api", .working), base.session("web", .idle)])
        use(st)
        let t = Task { await Self.call("sessions.wait", ["name": .string("api"), "timeout": .number(20)]) }
        await checks(1)
        st.sessions = [base.session("api", .blocked), base.session("web", .idle)]
        await checks(2)
        st.sessions = [base.session("api", .done), base.session("web", .working)]
        let r = await t.value
        XCTAssertEqual(r.result, .object(["reached": .bool(true), "state": .string("done")]), r.error ?? "")
        XCTAssertEqual(ControlSessionsRead.waitChecks, 3)
        st.sessions = [base.session("api", .working)]
        XCTAssertEqual(ControlSessionsRead.waitChecks, 3, "the subscription ends with the call")
    }

    /// changed:true skips the current value (idle now does not answer); the next store change to idle does.
    /// Without it the current idle value answers at once.
    func testWaitChangedSkipsTheCurrentValue() async {
        let api = base.session("api", .idle)
        let st = base.store([api, base.session("web", .working)])
        use(st)
        let t = Task { await Self.call("sessions.wait", ["name": .string("api"), "changed": .bool(true), "timeout": .number(20)]) }
        await checks(1)
        st.sessions = [api, base.session("web", .idle)] // another session changes: the target is unchanged, no answer
        await checks(2)
        st.sessions = [base.session("api", .working), base.session("web", .idle)]
        await checks(3)
        st.sessions = [base.session("api", .idle, ago: 5), base.session("web", .idle)] // idle again, later activity
        let r = await t.value
        XCTAssertEqual(r.result, .object(["reached": .bool(true), "state": .string("idle")]), r.error ?? "")
        XCTAssertEqual(ControlSessionsRead.waitChecks, 4)
        let now = await Self.call("sessions.wait", name("api"))
        XCTAssertEqual(now.result, .object(["reached": .bool(true), "state": .string("idle")]))
    }

    /// A session that leaves the list ends the wait ({"ended": true}), or reaches state "ended"; a state that already
    /// holds answers at once; an unknown or ambiguous name and a bad state or timeout are refused before any wait.
    func testWaitEndedAndRefusals() async {
        let st = base.store([base.session("api", .working), base.session("web", .blocked)])
        use(st)
        let t = Task { await Self.call("sessions.wait", ["name": .string("api")]) }
        await checks(1)
        st.sessions = [base.session("web", .blocked)]
        let ended = await t.value
        XCTAssertEqual(ended.result, .object(["ended": .bool(true)]))

        ControlSessionsRead.resetCounts()
        st.sessions = [base.session("api", .working)]
        let e = Task { await Self.call("sessions.wait", ["name": .string("api"), "state": .string("ended")]) }
        await checks(1)
        st.sessions = []
        let gone = await e.value
        XCTAssertEqual(gone.result, .object(["reached": .bool(true), "state": .string("ended")]))

        st.sessions = [base.session("web", .blocked)]
        let now = await Self.call("sessions.wait", ["name": .string("web"), "state": .string("needs-you")])
        XCTAssertEqual(now.result, .object(["reached": .bool(true), "state": .string("needs-you")]))
        let old = await Self.call("sessions.wait", name("old"))
        XCTAssertEqual(old.error, "no live session named old (sessions.list lists them)")
        st.sessions = [base.session("a", .idle, alias: "Same"), base.session("b", .idle, alias: "Same")]
        let same = await Self.call("sessions.wait", name("Same"))
        XCTAssertEqual(same.error, "2 sessions are named Same: rename one first")
        let soon = await Self.call("sessions.wait", ["name": .string("a"), "state": .string("soon")])
        XCTAssertEqual(soon.error, "argument 'state' must be one of idle, needs-you, ended")
        let zero = await Self.call("sessions.wait", ["name": .string("a"), "timeout": .number(0)])
        XCTAssertEqual(zero.error, ControlXray.badTimeout)
        let over = await Self.call("sessions.wait", ["name": .string("a"), "timeout": .number(61)])
        XCTAssertEqual(over.error, ControlXray.badTimeout)
    }

    /// No state in time: the timeout's own error, and the subscription is gone with the call.
    func testWaitTimesOut() async {
        let st = base.store([base.session("api", .working)])
        use(st)
        ControlXray.sleep = { _ in }
        let r = await Self.call("sessions.wait", ["name": .string("api"), "timeout": .number(2)])
        XCTAssertEqual(r.error, "sessions.wait: the session was not idle within 2 s (timeout); ask again")
        let n = ControlSessionsRead.waitChecks
        st.sessions = [base.session("api", .idle)]
        XCTAssertEqual(ControlSessionsRead.waitChecks, n, "no observer outlives a timed-out wait")
    }

    // MARK: - the switch

    /// #1854: every read answers with the agent-control switch off, screen and transcript included (the mutating
    /// commands stay gated: ControlSessionsTalkTests' say/interrupt rows).
    func testScreenAndTranscriptAnswerWhileSwitchOff() async {
        use(base.store([base.session("api", .idle, path: "/Users/example/t.jsonl")]))
        let calls = Calls()
        ControlSessionsRead.readScreen = { _ in calls.bump(); return Data("x".utf8) }
        Preferences.agentControlEnabled = false
        defer { Preferences.agentControlEnabled = true }
        let screen = await Self.call("sessions.screen", name("api"))
        XCTAssertEqual(obj(screen.result)["text"], .string("x"))
        XCTAssertEqual(calls.count, 1)
        // The fake path has no file: the read is reached and fails on the file, not on the switch.
        let transcript = await Self.call("sessions.transcript", name("api"))
        XCTAssertTrue(transcript.error != ControlChanges.offError)
        XCTAssertEqual(transcript.error, "the transcript cannot be read")
        let got = await Self.call("sessions.get", name("api"))
        XCTAssertEqual(obj(got.result)["name"], .string("api"))
    }

    // MARK: - sessions.screen

    /// One read of the session's own key per call; the last `lines` lines, trailing blank lines dropped.
    func testScreenReadsTheSessionOncePerCall() async {
        use(base.store([base.session("api", .working, dir: "/Users/example/dch")]))
        let calls = Calls()
        ControlSessionsRead.readScreen = { key in
            calls.bump()
            return key == AgentSessionKey(dir: "/Users/example/dch", name: "api") ? Data("one\ntwo\nthree\n   \n\n".utf8) : nil
        }
        let r = await Self.call("sessions.screen", ["name": .string("api"), "lines": .number(2)])
        XCTAssertEqual(obj(r.result)["text"], .string("two\nthree"), r.error ?? "")
        XCTAssertEqual(obj(r.result)["lines"], .number(2))
        XCTAssertEqual(calls.count, 1)
        for bad in [0, 2.5, 501] {
            let r = await Self.call("sessions.screen", ["name": .string("api"), "lines": .number(bad)])
            XCTAssertEqual(r.error, "argument 'lines' must be a whole number from 1 to 500")
        }
        let half = await Self.call("sessions.screen", ["name": .string("api"), "timeout": .number(0.5)])
        XCTAssertEqual(half.error, ControlXray.badTimeout)
        XCTAssertEqual(calls.count, 1, "a refused call reads nothing")
    }

    /// The deadline wins: the timeout's error, and the read in flight is cancelled (the product's SIGTERMs its dch).
    func testScreenTimeoutCancelsTheRead() async {
        use(base.store([base.session("api", .working)]))
        let calls = Calls()
        ControlSessionsRead.readScreen = { _ in
            calls.bump()
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                if Task.isCancelled { calls.cancel(); return nil }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return Data("late".utf8)
        }
        ControlXray.sleep = { _ in }
        let r = await Self.call("sessions.screen", ["name": .string("api"), "timeout": .number(3)])
        XCTAssertEqual(r.error, ControlXray.timedOut("sessions.screen", 3))
        XCTAssertEqual(calls.cancelled, 1, "the losing read was cancelled before the reply")
    }

    func testScreenTextNoAnswerNoMirrorAndCap() {
        guard case .failure(let e) = ControlSessionsRead.screenText(nil, name: "api", lines: 5) else { return XCTFail("nil read") }
        XCTAssertEqual(e.message, "could not read api's screen: dch did not answer")
        guard case .failure(let m) = ControlSessionsRead.screenText(Data(), name: "api", lines: 5) else { return XCTFail("empty") }
        XCTAssertEqual(m.message, "api has no screen mirror (dch lite or too old)")
        let wide = Data(String(repeating: "x", count: ControlSessionsRead.screenMaxChars + 10).utf8)
        guard case .success(let j) = ControlSessionsRead.screenText(wide, name: "api", lines: 5),
              case .string(let t)? = obj(j)["text"] else { return XCTFail("wide") }
        XCTAssertEqual(t.count, ControlSessionsRead.screenMaxChars)
    }

    // MARK: - sessions.transcript

    func lines() -> [String] {
        [#"{"type":"user","message":{"role":"user","content":"first"}}"#,
         #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"second"}]}}"#,
         #"{"type":"user","isSidechain":true,"agentId":"a1","message":{"role":"user","content":"side"}}"#,
         #"{"type":"user","message":{"role":"user","content":"third"}}"#]
    }

    func writeTranscript() throws -> (path: String, starts: [UInt64], size: UInt64) {
        let url = tempDir("tr").appendingPathComponent("t.jsonl")
        var data = Data(), starts: [UInt64] = []
        for l in lines() {
            starts.append(UInt64(data.count))
            data += Data((l + "\n").utf8)
        }
        try data.write(to: url)
        return (url.path, starts, UInt64(data.count))
    }

    func texts(_ j: ControlJSON?) -> [String] {
        guard case .array(let a)? = obj(j)["entries"] else { return [] }
        return a.compactMap { if case .string(let s)? = obj($0)["text"] { s } else { nil } }
    }

    /// No since: the last `limit` main-thread entries (a subagent's left out), next = the file's end. since: the first
    /// `limit` from that offset, next = the line after the last one read. Past the end and a missing file are errors.
    func testReadTranscriptTailAndSince() throws {
        let (path, starts, size) = try writeTranscript()
        guard case .success(let tail) = ControlSessionsRead.readTranscript(path: path, since: nil, limit: 2) else { return XCTFail("tail") }
        XCTAssertEqual(texts(tail), ["second", "third"])
        XCTAssertEqual(obj(tail)["next"], .number(Double(size)))
        guard case .success(let all) = ControlSessionsRead.readTranscript(path: path, since: nil, limit: 50) else { return XCTFail("all") }
        XCTAssertEqual(texts(all), ["first", "second", "third"])
        guard case .array(let entries)? = obj(all)["entries"] else { return XCTFail("entries") }
        XCTAssertEqual(obj(entries.first)["kind"], .string("user"))
        XCTAssertEqual(obj(entries.first)["at"], .number(0))
        XCTAssertEqual(obj(entries.last)["at"], .number(Double(starts.last ?? 0)))

        let from = starts.count > 1 ? starts[1] : 0
        guard case .success(let page) = ControlSessionsRead.readTranscript(path: path, since: from, limit: 1) else { return XCTFail("since") }
        XCTAssertEqual(texts(page), ["second"])
        XCTAssertEqual(obj(page)["next"], .number(Double(starts.count > 2 ? starts[2] : 0)))
        guard case .success(let end) = ControlSessionsRead.readTranscript(path: path, since: size, limit: 5) else { return XCTFail("end") }
        XCTAssertEqual(texts(end), [])
        XCTAssertEqual(obj(end)["next"], .number(Double(size)), "nothing new: next stays")
        guard case .failure(let past) = ControlSessionsRead.readTranscript(path: path, since: size + 1, limit: 5) else { return XCTFail("past") }
        XCTAssertEqual(past.message, "since is past the transcript's end (\(size) bytes)")
        guard case .failure(let gone) = ControlSessionsRead.readTranscript(path: path + ".x", since: nil, limit: 5) else { return XCTFail("gone") }
        XCTAssertEqual(gone.message, "the transcript cannot be read")

        // One line with two entries (text and a tool call): the tail still returns at most `limit`.
        let two = tempDir("tr2").appendingPathComponent("t.jsonl")
        try Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"x"},"#
            + #"{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"# + "\n").utf8).write(to: two)
        guard case .success(let one) = ControlSessionsRead.readTranscript(path: two.path, since: nil, limit: 1),
              case .array(let e)? = obj(one)["entries"] else { return XCTFail("two") }
        XCTAssertEqual(e.count, 1)
    }

    /// The work counted in lines: a limit-1 tail decodes one line (newest first), a cancelled read decodes none.
    func testTranscriptDecodesOnlyWhatItNeedsAndStopsWhenCancelled() async throws {
        let (path, _, _) = try writeTranscript()
        ControlSessionsRead.resetCounts()
        guard case .success(let one) = ControlSessionsRead.readTranscript(path: path, since: nil, limit: 1) else { return XCTFail("one") }
        XCTAssertEqual(texts(one), ["third"])
        XCTAssertEqual(ControlSessionsRead.decoded.value, 1)
        let r = await Task.detached { () -> Result<ControlJSON, ControlError> in
            withUnsafeCurrentTask { $0?.cancel() }
            return ControlSessionsRead.readTranscript(path: path, since: nil, limit: 50)
        }.value
        guard case .failure(let e) = r else { return XCTFail("a cancelled read answered") }
        XCTAssertEqual(e, ControlSessionsRead.cancelled)
        XCTAssertEqual(ControlSessionsRead.decoded.value, 1)
    }

    /// A cancel of the awaiting task reaches the detached read (a task group's cancelAll alone would not).
    func testOffMainCancelReachesTheRead() async {
        let calls = Calls()
        let outer = Task {
            await ControlSessionsRead.offMain {
                let end = Date().addingTimeInterval(5)
                while Date() < end {
                    if Task.isCancelled { calls.cancel(); return .failure(ControlSessionsRead.cancelled) }
                    usleep(1_000)
                }
                return .success(.null)
            }
        }
        outer.cancel()
        let r = await outer.value
        XCTAssertEqual(calls.cancelled, 1)
        XCTAssertTrue(r == .failure(ControlSessionsRead.cancelled))
    }

    /// Through the command: no mapped transcript is refused at once; else the entries of one read off main.
    func testTranscriptCommandAnswers() async throws {
        let (path, _, _) = try writeTranscript()
        use(base.store([base.session("api", .idle, path: path), base.session("sh", .idle)]))
        let sh = await Self.call("sessions.transcript", name("sh"))
        XCTAssertEqual(sh.error, "sh has no transcript Prosper can read (not a Claude Code session dch mapped)")
        let r = await Self.call("sessions.transcript", ["name": .string("api"), "limit": .number(1)])
        XCTAssertEqual(texts(r.result), ["third"], r.error ?? "")
        let neg = await Self.call("sessions.transcript", ["name": .string("api"), "since": .number(-1)])
        XCTAssertEqual(neg.error, "argument 'since' must be a whole number from 0 to \(1 << 53)")
        let slow = await Self.call("sessions.transcript", ["name": .string("api"), "timeout": .number(61)])
        XCTAssertEqual(slow.error, ControlXray.badTimeout)
    }

    // MARK: - registry

    func testRegisteredAsReads() {
        var r = ControlRegistry()
        ControlRegistry.registerSessionsRead(&r)
        XCTAssertEqual(r.commands.keys.sorted(), ["sessions.get", "sessions.screen", "sessions.transcript", "sessions.wait"])
        XCTAssertTrue(r.commands.values.allSatisfy { !$0.mutates })
        XCTAssertTrue(r.commands["sessions.get"]?.runAsync == nil)
        for n in ["sessions.screen", "sessions.transcript", "sessions.wait"] { XCTAssertTrue(r.commands[n]?.runAsync != nil, n) }
    }
}
