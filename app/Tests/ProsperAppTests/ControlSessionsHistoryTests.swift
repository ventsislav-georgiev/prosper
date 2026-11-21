import Foundation
import XCTest
@testable import ProsperApp

/// #1833: sessions.history and sessions.resume over the control channel. The window model's own fakes (AgentWindowD1Tests,
/// AgentWindowRemoteHistoryTests): no dch, no window shown, no real island controller. ControlSessions' seams are put back
/// after each row.
final class ControlSessionsHistoryTests: XCTestCase {
    let base = AgentWindowD1Tests()
    let remote = AgentWindowRemoteHistoryTests()
    /// The resume seam's calls ("<name> <noMessage>") and its answer, on self: the seam is a @MainActor closure.
    var calls: [String] = []
    var started = true

    @MainActor
    func withSeams(model: AgentWindowModel? = nil, store: AgentIslandStore? = nil,
                   _ body: () throws -> Void) rethrows {
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow, ControlSessions.resumeRecord)
        defer { (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow, ControlSessions.resumeRecord) = saved }
        ControlSessions.model = { model }
        ControlSessions.islandStore = { store }
        ControlSessions.showWindow = { nil }
        calls = []
        started = true
        ControlSessions.resumeRecord = { r, quiet in self.calls.append("\(r.name) \(quiet)"); return self.started }
        try body()
    }

    func args(_ d: [String: String], noMessage: Bool? = nil) -> [String: ControlJSON] {
        var a = d.mapValues { ControlJSON.string($0) }
        if let noMessage { a["noMessage"] = .bool(noMessage) }
        return a
    }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func rows(_ j: ControlJSON) -> [String: [String: ControlJSON]] {
        guard case .object(let o) = j, case .array(let a)? = o["history"] else { return [:] }
        var out: [String: [String: ControlJSON]] = [:]
        for case .object(let r) in a { if case .string(let n)? = r["id"] { out[n] = r } }
        return out
    }

    /// History: api (a Claude, its name live now), web (a shell) and a record whose name dch would read as a flag.
    @MainActor
    func historyStore() -> AgentIslandStore {
        var api = base.record("api"), web = base.record("web")
        api.argv = ["claude"]
        web.argv = ["/bin/zsh"]
        web.pinned = true
        // The live session's master is 1.24.0: a master raises every gate to its own version (DchCommand.gate).
        var live = base.session("api", .idle)
        live.version = "1.24.0"
        let st = base.store([live], history: [api, web, base.record("--all")])
        // Resume's gate open (1.24.0), Resume (no message)'s closed (1.27.0).
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 26, 0])
        return st
    }

    // MARK: - sessions.history

    /// Every History record with its fields and the History menu's gates: Resume on, Resume (no message) off with its
    /// reason, a flag-shaped name off with the menu's reason; with no window the island's store alone.
    @MainActor
    func testSessionsHistoryListsRecordsWithTheMenusGates() throws {
        let st = historyStore(), m = base.windowModel(st)
        defer { m.close() }
        let quietOff = "Not run: Resume (no message) (needs dch 1.27.0)"
        try withSeams(model: m) {
            let r = rows(try ControlSessions.history())
            XCTAssertEqual(r.count, 3)
            XCTAssertEqual(r["api"]?["name"], .string("api"))
            XCTAssertEqual(r["api"]?["cwd"], .string("/Users/example/api"))
            XCTAssertEqual(r["api"]?["ended"], .number(AgentWindowD1Tests.now - 3600))
            XCTAssertEqual(r["api"]?["status"], .string(AgentIsland.endLabel("exit 0")))
            XCTAssertEqual(r["api"]?["age"], .string(AgentIsland.age(3600)))
            XCTAssertEqual(r["api"]?["pinned"], .bool(false))
            XCTAssertEqual(r["web"]?["pinned"], .bool(true))
            XCTAssertEqual(r["api"]?["host"], .null)
            XCTAssertEqual(r["api"]?["resume"], .bool(true))
            XCTAssertEqual(r["api"]?["resumeWhyNot"], .null)
            XCTAssertEqual(r["api"]?["resumeNoMessage"], .bool(false))
            XCTAssertEqual(r["api"]?["resumeNoMessageWhyNot"], .string(quietOff))
            XCTAssertEqual(r["--all"]?["resume"], .bool(false))
            XCTAssertEqual(r["--all"]?["resumeWhyNot"], .string("Not run: Resume (not available for this session)"))
            st.historyActions[AgentSessionKey(dir: "/tmp/dch-test", name: "web")] = AgentIsland.resumingText
            XCTAssertEqual(rows(try ControlSessions.history())["web"]?["action"], .string(AgentIsland.resumingText))
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 27, 0])
            XCTAssertEqual(rows(try ControlSessions.history())["api"]?["resumeNoMessage"], .bool(true), "the gate open: on")
        }
        try withSeams(store: st) { XCTAssertEqual(rows(try ControlSessions.history()).count, 3, "no window: the island's store") }
        try withSeams { refused(try ControlSessions.history(), ControlSessions.islandOff) }
    }

    // MARK: - sessions.resume (this Mac)

    /// The menu's gate, then the controller's resume once with the record and noMessage; a message resumes as Resume (no
    /// message) and goes after it to the name it revives as (the first prompt's sayFirst seam). Refusals run nothing; no undo.
    @MainActor
    func testSessionsResumeTakesTheMenusGateTheControllerAndTheFirstPromptPath() throws {
        let st = historyStore(), m = base.windowModel(st)
        defer { m.close() }
        var said: [String] = []
        m.sayFirst = { key, text, _ in said.append("\(key.name): \(text)") }
        try withSeams(model: m) {
            // #1833 r1: a message replaces dch's carry-on message: it resumes as Resume (no message), on that gate.
            refused(try ControlSessions.resume(args(["id": "api", "message": "hello"])), "Not run: Resume (no message) (needs dch 1.27.0)")
            XCTAssertEqual(calls, [], "the no-message gate off: nothing runs")
            _ = try ControlSessions.resume(args(["id": "web"]))
            XCTAssertEqual(calls, ["web false"], "no message: the plain Resume")
            refused(try ControlSessions.resume(args(["id": "web"], noMessage: true)), "Not run: Resume (no message) (needs dch 1.27.0)")
            st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 27, 0])
            let ch = try ControlSessions.resume(args(["id": "api", "message": "hello"]))
            XCTAssertEqual(calls, ["web false", "api true"], "a message resumes without dch's carry-on message")
            XCTAssertEqual(said, ["api-2: hello"], "api is live: it revives as api-2 and the message goes there")
            XCTAssertEqual(ch.result, .string("api-2"))
            XCTAssertEqual(ch.verb, "resumed")
            XCTAssertTrue(ch.undo == nil, "a resume is not reversible")
            XCTAssertTrue(ch.summary.contains("no undo"), ch.summary)
            refused(try ControlSessions.resume(args(["id": "api", "message": "hello"], noMessage: false)),
                    "message already resumes without dch's carry-on message")
            _ = try ControlSessions.resume(args(["id": "web"], noMessage: true))
            XCTAssertEqual(calls.last, "web true", "Resume (no message)")
            XCTAssertEqual(said.count, 1, "no message: nothing said")
            refused(try ControlSessions.resume(args(["id": "web", "message": "hi"])), "a message needs a Claude Code session")
            refused(try ControlSessions.resume(args(["id": "--all"])), "Not run: Resume (not available for this session)")
            refused(try ControlSessions.resume(args(["id": "nope"])), "no History record nope (sessions.history lists them)")
            XCTAssertEqual(calls.count, 3, "a refusal runs nothing")
            started = false
            refused(try ControlSessions.resume(args(["id": "api", "message": "hello"])), "api is busy: try again")
            XCTAssertEqual(said.count, 1, "nothing started: nothing said")
            started = true
            st.controlDch = nil
            calls = []
            refused(try ControlSessions.resume(args(["id": "api"])), "Not run: Resume (needs dch 1.24.0)")
            XCTAssertEqual(calls, [], "a closed gate runs nothing")
        }
    }

    // MARK: - sessions.resume (another Mac)

    /// Another Mac's record (the window's History rows with a host): listed as "host:id", resumed through resumeRemote
    /// once; a second while it runs, Resume (no message) and a message are refused and run nothing.
    @MainActor
    func testSessionsResumeOfAnotherMacsRecordGoesThroughResumeRemote() throws {
        let verbs = AgentWindowRemoteHistoryTests.Verbs()
        let (m, _, _) = remote.model(AgentWindowRemoteHistoryTests.Lister(AgentWindowRemoteHistoryTests.fixture), verbs: verbs,
                                      lister: AgentWindowRemoteHistoryTests.Lister(AgentWindowRemoteHistoryTests.list))
        defer { m.close() }
        remote.spin { m.rows.contains { $0.host != nil } }
        try withSeams(model: m) {
            let r = rows(try ControlSessions.history())
            XCTAssertEqual(r["host-a:api"]?["host"], .string("host-a"))
            XCTAssertEqual(r["host-a:api"]?["resumeNoMessage"], .bool(false))
            XCTAssertEqual(r["old"]?["host"], .null, "this Mac's record first")
            refused(try ControlSessions.resume(args(["id": "host-a:api"], noMessage: true)),
                    "Not run: Resume (no message) (this Mac's records only)")
            refused(try ControlSessions.resume(args(["id": "host-a:api", "message": "hi"])), "a message goes only to a session on this Mac")
            XCTAssertEqual(verbs.calls.count, 0)
            XCTAssertEqual(calls, [], "another Mac's record never takes this Mac's resume")
            let ch = try ControlSessions.resume(args(["id": "host-a:api"]))
            XCTAssertEqual(verbs.calls.count, 1)
            XCTAssertEqual(verbs.calls.last?.args, ["--host", "host-a", "--revive", "api.json", "--json"])
            XCTAssertEqual(ch.result, .string("api"))
            refused(try ControlSessions.resume(args(["id": "host-a:api"])), "api is busy: try again")
            XCTAssertEqual(verbs.calls.count, 1, "running: not run again")
            verbs.answer = false
            refused(try ControlSessions.resume(args(["id": "host-a:docs"])), "Docs is busy: try again")
        }
    }

    // MARK: - Registration and the wire

    /// sessions.history a read, sessions.resume a change; noMessage is checked as a boolean before the handler.
    @MainActor
    func testRegisterSessionsAddsHistoryAndResume() async throws {
        var reg = ControlRegistry()
        ControlRegistry.registerSessions(&reg)
        XCTAssertEqual(reg.commands["sessions.history"]?.mutates, false)
        XCTAssertEqual(reg.commands["sessions.resume"]?.mutates, true)
        XCTAssertEqual(reg.commands["sessions.resume"]?.args["noMessage"]?.type, "boolean")
        let registry = reg
        let bad = await registry.reply(to: Data(#"{"cmd":"sessions.resume","args":{"id":"api","noMessage":"yes"}}"#.utf8))
        XCTAssertEqual(bad, .failure("argument 'noMessage' must be boolean, got string"))
    }
}
