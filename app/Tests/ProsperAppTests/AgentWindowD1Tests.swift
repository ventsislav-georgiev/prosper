import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #797 Agent window D1: the sidebar (fed by the island store), selection driving
/// the one transcript model, the energy rule, keyboard, the #786 review
/// prerequisites, and offscreen renders of the window. Offscreen only: the window
/// is never shown, key events are built and handed to a never-shown window, and no
/// event is posted.
final class AgentWindowD1Tests: XCTestCase {

    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-code", isDirectory: true)

    static let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    static let now: TimeInterval = 1_800_000_000

    func line(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8)
    }

    func entry(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["type": type, "sessionId": "s-1", "version": "2.1.300"]
        o.merge(extra) { $1 }
        return o
    }

    func assistant(_ blocks: [[String: Any]], _ extra: [String: Any] = [:]) -> [String: Any] {
        entry("assistant", ["message": ["role": "assistant", "content": blocks]].merging(extra) { $1 })
    }

    func say(_ text: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        assistant([["type": "text", "text": text]], extra)
    }

    func toolUse(_ id: String, _ name: String, _ input: [String: Any], _ extra: [String: Any] = [:]) -> [String: Any] {
        assistant([["type": "tool_use", "id": id, "name": name, "input": input]], extra)
    }

    func toolResult(_ id: String, _ text: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]],
                       "toolUseResult": ["stdout": text, "stderr": ""]].merging(extra) { $1 })
    }

    func asm(_ es: [[String: Any]], maxPending: Int = 256) -> TranscriptAssembler {
        var a = TranscriptAssembler()
        a.maxPending = maxPending
        for e in es { a.add(TranscriptDecoder.decode(line: line(e)), source: nil) }
        return a
    }

    func write(_ url: URL, _ entries: [[String: Any]]) throws {
        try entries.map(line).reduce(Data(), +).write(to: url)
    }

    func append(_ url: URL, _ data: Data) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: data)
        try h.close()
    }

    func session(_ name: String, _ state: AgentState, ago: TimeInterval = 60, alias: String = "", agents: Int = 0,
                 dir: String = "/tmp/dch-test", meta: DchSessionMeta? = nil, path: String? = nil) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: alias, activity: Self.now - ago, state: state,
                     agents: agents, meta: meta, version: "1.30.0",
                     claudeSessionID: path == nil ? nil : "0b7c2f3e-1111-2222-3333-444455556666", transcriptPath: path)
    }

    func record(_ name: String, ago: TimeInterval = 3600) -> DchHistoryRecord {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: name))
        r.cwd = "/Users/example/\(name)"
        r.ended = Self.now - ago
        r.updated = Self.now - ago
        r.end = "exit 0"
        return r
    }

    @MainActor
    func store(_ sessions: [AgentSession], history: [DchHistoryRecord] = [], pattern: String = "") -> AgentIslandStore {
        let s = AgentIslandStore(geometry: Self.geometry)
        s.sidekickPattern = pattern
        s.sessions = sessions
        s.history = history
        return s
    }

    /// A window model with every outside effect replaced: nothing reaches the island
    /// controller, a terminal or the file watcher.
    @MainActor
    func windowModel(_ store: AgentIslandStore?, opened: @escaping (AgentSession) -> Void = { _ in },
                     visible: @escaping (Bool) -> Void = { _ in }) -> AgentWindowModel {
        let m = AgentWindowModel()
        m.now = { Self.now }
        m.openSession = opened
        m.resume = { _ in }
        m.onVisible = visible
        m.ageInterval = 3600
        m.transcript.offMain = { $0() }
        m.transcript.makeWatch = { _, _ in NSObject() }
        m.transcript.tickInterval = 3600
        m.bind(store)
        return m
    }

    // MARK: - The mapping rides on the island's own --ls-json read

    func testAgentWindowMappingKeepsOnlyAWellFormedIdAndAbsoluteJsonlPath() {
        let json = #"""
        [{"name":"ok","claude_session_id":"0b7c2f3e-aaaa-bbbb-cccc-0123456789ab","transcript_path":"/Users/x/.claude/projects/p/0b7c2f3e-aaaa-bbbb-cccc-0123456789ab.jsonl"},
         {"name":"camel","claudeSessionId":"abc","transcriptPath":"/a/abc.jsonl"},
         {"name":"other","claude_session_id":"abc","transcript_path":"/a/abd.jsonl"},
         {"name":"prefix","claude_session_id":"abc","transcript_path":"/a/xabc.jsonl"},
         {"name":"rel","claude_session_id":"abc","transcript_path":"p/0b7c.jsonl"},
         {"name":"dots","claude_session_id":"abc","transcript_path":"/a/../etc/x.jsonl"},
         {"name":"ext","claude_session_id":"abc","transcript_path":"/a/b.json"},
         {"name":"weird","claude_session_id":"abc; rm","transcript_path":"/a/b.jsonl"},
         {"name":"null","claude_session_id":null,"transcript_path":null},
         {"name":"half","claude_session_id":"abc"},
         {"name":"num","claude_session_id":7,"transcript_path":"/a/b.jsonl"}]
        """#
        let m = AgentTranscriptMapping.parse(Data(json.utf8))
        XCTAssertEqual(Set(m.keys), ["ok", "camel"])
        XCTAssertEqual(m["ok"]?.path, "/Users/x/.claude/projects/p/0b7c2f3e-aaaa-bbbb-cccc-0123456789ab.jsonl")
        XCTAssertEqual(AgentTranscriptMapping.parse(Data("{\"name\":1}".utf8)), [:], "not an array: nothing")
        XCTAssertEqual(AgentTranscriptMapping.parse(Data()), [:])
    }

    func testAgentWindowListCarriesTheMappingWithOneForkPerDir() {
        var calls: [[String]] = []
        let json = #"""
        [{"name":"x","alias":"","activity_epoch":42,"state":"working","agents":0,"version":"1.30.0",
          "claude_session_id":"abcd-12","transcript_path":"/u/p/abcd-12.jsonl"},
         {"name":"y","alias":"","activity_epoch":43,"state":"idle","agents":0}]
        """#
        let rows = AgentIsland.list(dirs: ["/tmp/dch-501"]) { args, _ in calls.append(args); return Data(json.utf8) }
        XCTAssertEqual(calls, [["--ls-json"]], "the window adds no dch fork")
        XCTAssertEqual(rows.map(\.claudeSessionID), ["abcd-12", nil])
        XCTAssertEqual(rows.map(\.transcriptPath), ["/u/p/abcd-12.jsonl", nil])
        XCTAssertEqual(AgentSidebar.source(rows[0]).transcriptPath, "/u/p/abcd-12.jsonl")
        XCTAssertEqual(AgentSidebar.source(rows[0]).dchState, "working")
    }

    // MARK: - Sidebar

    func testAgentWindowSidebarPutsNeedsYouFirstThenTheIslandGroupsThenHistory() {
        let sessions = [session("idle-one", .idle, ago: 5), session("worker", .working, ago: 30),
                        session("finished", .done, ago: 10), session("asking", .blocked, ago: 900),
                        session("qa-797", .working, ago: 20), session("qa-798", .blocked, ago: 1),
                        session("asking-newer", .blocked, ago: 100)]
        let secs = AgentSidebar.sections(sessions: sessions, history: [record("old")], sort: .activity,
                                         sidekickPattern: "qa-", details: .all, now: Self.now)
        XCTAssertEqual(secs.map(\.title), ["Needs you", "Sessions", "Sidekicks", "History"])
        XCTAssertEqual(secs[0].rows.map(\.title), ["qa-798", "asking-newer", "asking", "finished"],
                       "blocked before done, newest first; a sidekick that needs you is in Needs you")
        XCTAssertEqual(secs[1].rows.map(\.title), AgentIsland.sorted([sessions[0], sessions[1]], by: .activity).map(\.title),
                       "the island's own order")
        XCTAssertEqual(secs[2].rows.map(\.title), ["qa-797"])
        XCTAssertEqual(secs[3].rows.map(\.title), ["old"])
        let ids = secs.flatMap(\.rows).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no session shows twice")

        let byName = AgentSidebar.sections(sessions: sessions, history: [], sort: .name, sidekickPattern: "",
                                           details: .all, now: Self.now)
        XCTAssertEqual(byName.map(\.title), ["Needs you", "Sessions"], "no sidekick pattern, no history: no empty groups")
        XCTAssertEqual(byName[1].rows.map(\.title), ["idle-one", "qa-797", "worker"])
        XCTAssertEqual(AgentSidebar.sections(sessions: [], history: [], sort: .name, sidekickPattern: "", details: .all,
                                             now: Self.now), [])
    }

    func testAgentWindowSidebarRowShowsStateAgentsPRsAndAge() {
        let pr = { (n: Int) in DchSessionMeta.PR(url: "https://github.com/acme/prosper/pull/\(n)", repo: "acme/prosper", num: n, title: "t") }
        let s = session("prosper", .working, ago: 240, alias: "Prosper app", agents: 2,
                        meta: DchSessionMeta(openPRs: [pr(1), pr(2), pr(3)], merged: 4))
        let r = AgentSidebar.row(s, details: .all, now: Self.now)
        XCTAssertEqual(r.title, "Prosper app")
        XCTAssertEqual(r.state, .working)
        XCTAssertEqual(r.detail, "Working", "#1115: the counts are fields, drawn as symbol plus number")
        XCTAssertEqual([r.agents, r.merged], [2, 4])
        XCTAssertEqual(r.prs, ["prosper#1", "prosper#2", "+1"])
        XCTAssertEqual(r.prCount, 3)
        XCTAssertEqual(r.age, "", "#1114: a working row shows no age")
        XCTAssertEqual(AgentSidebar.row(session("prosper", .done, ago: 240), details: .all, now: Self.now).age, "4m")
        let quiet = AgentSidebar.row(s, details: AgentIslandRowDetails(agents: false, openPRs: false, merged: false), now: Self.now)
        XCTAssertEqual(quiet.detail, "Working", "the island's row-detail settings apply")
        XCTAssertEqual(quiet.prs, [])
        let h = AgentSidebar.row(record("gone", ago: 7200), now: Self.now)
        XCTAssertNil(h.state)
        XCTAssertTrue(h.detail.hasPrefix("Ended · "), h.detail)
        XCTAssertEqual(h.age, "2h")
    }

    func testAgentWindowStateMappingMatchesDch() {
        XCTAssertEqual(AgentState.allCases.map { AgentSidebar.source(session("s", $0)).dchState },
                       ["blocked", "working", "done", "idle"])
        XCTAssertEqual(AgentState.allCases.map { AgentState(dch: AgentSidebar.source(session("s", $0)).dchState) },
                       AgentState.allCases, "round-trips through dch's words")
        XCTAssertEqual(AgentState.allCases.filter { AgentSidebar.needsYou(session("s", $0)) }, [.blocked, .done])
    }

    // MARK: - Selection drives one transcript model

    @MainActor
    func testAgentWindowSelectionDrivesOneTranscriptAndStopsItOnDeselect() throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl")
        try write(a, [say("from a")])
        try write(b, [say("from b")])
        let st = store([session("a", .working, ago: 5, path: a.path), session("b", .idle, ago: 50, path: b.path)],
                       history: [record("h")])
        let m = windowModel(st)
        let t = m.transcript
        XCTAssertNil(m.selection, "nothing selected before the window shows")
        m.setVisible(true)
        XCTAssertEqual(m.selection, .live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")), "the first row")
        XCTAssertTrue(t.running)
        XCTAssertEqual(t.tail?.path, a.path)
        XCTAssertEqual(t.blocks.count, 1)

        m.move(1)
        XCTAssertTrue(m.transcript === t, "one model, rebound")
        XCTAssertEqual(t.source?.key.name, "b")
        XCTAssertEqual(t.tail?.path, b.path)
        guard case .assistant(let c) = t.blocks.first?.body else { return XCTFail("\(t.blocks)") }
        XCTAssertEqual(c.text, "from b")

        m.move(1)
        XCTAssertEqual(m.selection, .history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")))
        XCTAssertFalse(t.running, "a History row tails nothing")
        XCTAssertTrue(t.blocks.isEmpty)
        m.move(5)
        XCTAssertEqual(m.selection, .history(AgentSessionKey(dir: "/tmp/dch-test", name: "h")), "clamped")

        m.move(-2)
        XCTAssertEqual(t.tail?.path, a.path)
        XCTAssertTrue(t.running)
        // The selected session ends: its row goes, nothing stays tailed. QA #626 INFO-4:
        // nothing is selected (the hint), never another conversation.
        st.sessions = [session("b", .idle, ago: 50, path: b.path)]
        XCTAssertNil(m.selection, "the ended row leaves nothing selected")
        XCTAssertFalse(t.running)
        st.sessions = [session("b", .idle, ago: 40, path: b.path), session("c", .idle, ago: 30)]
        XCTAssertNil(m.selection, "only the window's first fill picks the first row")
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "b")))
        XCTAssertEqual(t.tail?.path, b.path)
        m.select(nil)
        XCTAssertFalse(t.running, "deselect stops it")
    }

    @MainActor
    func testAgentWindowOpensTheSelectedSessionThroughTheIslandAndKeysMoveIt() {
        var opened: [String] = []
        let st = store([session("one", .working, ago: 1), session("two", .idle, ago: 2)], history: [record("h")])
        let m = windowModel(st, opened: { opened.append($0.name) })
        showTranscript(m)   // #845: Return moves into the input box in Transcript mode (no longer opens the app)
        m.setVisible(true)
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)!
        }
        win.sendEvent(key(125))   // down
        XCTAssertEqual(m.selection, .live(AgentSessionKey(dir: "/tmp/dch-test", name: "two")))
        win.sendEvent(key(36))    // Return
        XCTAssertTrue(m.interaction.composerFocusPending, "#845: into the input box (built by the pane)")
        win.sendEvent(key(126))   // up
        XCTAssertFalse(m.interaction.composerFocusPending, "another session: the pending focus is dropped")
        win.sendEvent(key(76))    // keypad Enter
        XCTAssertTrue(m.interaction.composerFocusPending)
        XCTAssertEqual(opened, [], "#845: Return opens no terminal app (the header's Open in terminal does)")
        // Review round 1 (g): any modifier passes through, each one on its own.
        let at = m.selection
        for flag: NSEvent.ModifierFlags in [.shift, .option, .control, .command] {
            for code: UInt16 in [125, 126, 36, 76] {
                XCTAssertFalse(AgentsNSWindow.handle(key(code, flag), m), "key \(code) with \(flag.rawValue) passes through")
            }
        }
        XCTAssertEqual(m.selection, at, "no modified arrow moved the selection")
        XCTAssertEqual(opened, [], "no modified Return opened anything")
        XCTAssertFalse(AgentsNSWindow.handle(key(0), m), "other keys pass through")
        m.move(5)
        XCTAssertFalse(AgentsNSWindow.handle(key(36), m), "Return on a History row passes on")
        XCTAssertFalse(m.interaction.composerFocusPending)
        XCTAssertEqual(opened, [], "Return on a History row opens nothing")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    // MARK: - Energy

    @MainActor
    func testAgentWindowNothingRunsWhileHiddenOrClosed() throws {
        let url = tempDir().appendingPathComponent("e.jsonl")
        try write(url, [say("hello")])
        let st = store([session("s", .working, ago: 5, path: url.path)])
        var shown: [Bool] = []
        let m = windowModel(st, visible: { shown.append($0) })
        let t = m.transcript

        XCTAssertEqual(m.refreshes, 0, "bound but not visible: nothing is built")
        XCTAssertTrue(m.sections.isEmpty)
        XCTAssertFalse(t.running)
        XCTAssertNil(m.clock)
        XCTAssertEqual(t.watchArms, 0)
        st.sessions = [session("s", .working, ago: 1, path: url.path)]
        XCTAssertEqual(m.refreshes, 0, "store changes while hidden cost nothing")

        m.setVisible(true)
        XCTAssertEqual(shown, [true], "the island is told (it stops holding lists back)")
        XCTAssertNotNil(m.clock)
        XCTAssertTrue(t.running)
        XCTAssertEqual(t.watchArms, 1)
        let built = m.refreshes
        XCTAssertGreaterThan(built, 0)

        m.setVisible(false)   // miniaturized, occluded, another Space
        XCTAssertEqual(shown, [true, false])
        XCTAssertNil(m.clock, "no age clock while hidden")
        XCTAssertFalse(t.running, "no tail while hidden")
        XCTAssertTrue(t.blocks.isEmpty, "the blocks are freed")
        st.sessions = [session("s", .blocked, ago: 1, path: url.path)]
        XCTAssertEqual(m.refreshes, built)

        m.setVisible(true)
        XCTAssertEqual(m.sections.first?.title, "Needs you", "showing again reads the store afresh")
        XCTAssertTrue(t.running)
        m.close()
        XCTAssertEqual(shown, [true, false, true, false])
        XCTAssertFalse(t.running)
        XCTAssertNil(m.clock)
        let closed = m.refreshes
        st.sessions = []
        st.history = [record("x")]
        m.setVisible(true)
        m.bind(st)
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "s")))
        XCTAssertEqual(m.refreshes, closed, "closed for good")
        XCTAssertFalse(t.running)
        XCTAssertNil(m.clock)
        t.tick()
        t.poll()
        XCTAssertTrue(t.blocks.isEmpty)
    }

    @MainActor
    func testAgentWindowWithoutTheIslandSaysSoAndFollowsARebuiltStore() {
        let m = windowModel(nil)
        m.setVisible(true)
        defer { m.close() }
        XCTAssertFalse(m.hasStore)
        XCTAssertTrue(m.sections.isEmpty)
        XCTAssertNil(m.selection)
        let st = store([session("s", .idle)])
        m.bind(st)
        XCTAssertTrue(m.hasStore)
        XCTAssertEqual(m.rows.map(\.title), ["s"])
        m.bind(nil)
        XCTAssertFalse(m.hasStore)
        XCTAssertNil(m.selection)
        XCTAssertFalse(m.transcript.running)
    }

    // MARK: - #797 (a): reads, decoding and paging run off main

    @MainActor
    func testAgentWindowPollAndPagingRunOffMainAndPublishOnMain() throws {
        let url = tempDir().appendingPathComponent("o.jsonl")
        try write(url, (0..<60).map { say("message \($0) " + String(repeating: "x", count: 40)) })
        let m = AgentTranscriptModel()
        var jobs: [@Sendable () -> Void] = []
        m.offMain = { jobs.append($0) }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.pageBytes = 1024
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        XCTAssertEqual(jobs.count, 1, "start hands the read to the IO queue")
        XCTAssertTrue(m.blocks.isEmpty, "nothing was read on main")
        m.poll()
        XCTAssertEqual(jobs.count, 1, "one read in flight; the next waits for it")
        func runOffMain(_ job: @escaping @Sendable () -> Void) {
            let done = expectation(description: "job")
            DispatchQueue.global().async {
                XCTAssertFalse(Thread.isMainThread)
                job()
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))   // the hop back to main
        }
        runOffMain(jobs.removeFirst())
        XCTAssertGreaterThan(m.blocks.count, 0, "published on main after the hop")
        XCTAssertEqual(jobs.count, 1, "the poll asked for meanwhile runs after it")
        runOffMain(jobs.removeFirst())
        XCTAssertTrue(m.olderAvailable)

        let before = m.blocks.count
        m.loadEarlier()
        XCTAssertEqual(m.blocks.count, before, "paging is read off main too")
        XCTAssertEqual(jobs.count, 1)
        runOffMain(jobs.removeFirst())
        XCTAssertGreaterThan(m.blocks.count, before)
    }

    /// Review round 1 (e): "Load earlier" while a poll is in flight would hand off the
    /// same tail and assembler; whichever landed last would undo the other (an old
    /// offset, lines read twice, or a lost page). It waits instead.
    @MainActor
    func testAgentWindowLoadEarlierWaitsForAPollInFlight() throws {
        let url = tempDir().appendingPathComponent("busy.jsonl")
        try write(url, (0..<60).map { say("message \($0) " + String(repeating: "x", count: 40)) })
        let m = AgentTranscriptModel()
        var jobs: [@Sendable () -> Void] = []
        m.offMain = { jobs.append($0) }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.pageBytes = 1024
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        func drain() { while !jobs.isEmpty { jobs.removeFirst()() } }
        func texts() -> [String] { m.blocks.compactMap { if case .assistant(let c) = $0.body { c.text } else { nil } } }
        drain()
        XCTAssertTrue(m.olderAvailable)

        try append(url, (60..<63).map { line(say("new \($0)")) }.reduce(Data(), +))
        m.poll()
        XCTAssertEqual(jobs.count, 1, "the poll's read is in flight")
        m.loadEarlier()
        XCTAssertEqual(jobs.count, 1, "no page read while a poll is in flight")
        XCTAssertTrue(m.earlierAgain, "QA #626 INFO-3: the click is queued, never dropped")
        jobs.removeFirst()()   // the poll lands (main inline), then the queued page is handed off
        XCTAssertFalse(m.earlierAgain)
        XCTAssertEqual(jobs.count, 1, "the queued page read runs after the poll, alone")
        let afterPoll = m.blocks.count
        drain()
        XCTAssertGreaterThan(m.blocks.count, afterPoll, "the queued page landed")
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).uint64Value
        XCTAssertEqual(m.tail?.offset, size, "the offset moved forward to the end")
        XCTAssertEqual(Set(texts()).count, texts().count, "no line read twice: \(texts())")
        XCTAssertEqual(texts().last, "new 62")

        let before = m.blocks.count
        m.loadEarlier()
        XCTAssertEqual(jobs.count, 1, "once idle, paging runs")
        drain()
        XCTAssertGreaterThan(m.blocks.count, before)
        XCTAssertEqual(Set(texts()).count, texts().count)
        XCTAssertEqual(m.tail?.offset, size)
    }

    @MainActor
    func testAgentWindowTheDefaultIOQueueLoadsAndExpandsOffMain() async throws {
        let url = tempDir().appendingPathComponent("q.jsonl")
        let big = (0..<2000).map { "output line \($0)" }.joined(separator: "\n")
        try write(url, [toolUse("t1", "Bash", ["command": "seq"]), toolResult("t1", big)])
        let m = AgentTranscriptModel()
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        XCTAssertTrue(m.blocks.isEmpty, "start returns before the read")
        let deadline = Date().addingTimeInterval(5)
        while m.blocks.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .bash(_, _, let out?, _) = m.blocks.first?.body else { return XCTFail("\(m.blocks)") }
        XCTAssertTrue(out.capped)
        let full = await m.fullText(out)
        XCTAssertEqual(full, big)
    }

    @MainActor
    func testAgentWindowAReadForAnotherSessionIsDroppedWhenItLands() throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl")
        try write(a, [say("from a")])
        try write(b, [say("from b")])
        let m = AgentTranscriptModel()
        var jobs: [@Sendable () -> Void] = []
        m.offMain = { jobs.append($0) }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        func src(_ name: String, _ url: URL) -> AgentTranscriptSource {
            AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: name), dchVersion: "1.30.0", dchState: "idle",
                                  sessionId: name, transcriptPath: url.path)
        }
        m.update(src("a", a))
        m.start()
        defer { m.stop() }
        let stale = jobs.removeFirst()
        m.update(src("b", b))
        XCTAssertEqual(jobs.count, 1, "the new session reads at once, not behind the old read")
        let fresh = jobs.removeFirst()
        fresh()
        stale()   // a's read lands late
        XCTAssertEqual(m.blocks.count, 1)
        guard case .assistant(let c) = m.blocks.first?.body else { return XCTFail() }
        XCTAssertEqual(c.text, "from b", "a's late result never lands in b's view")
        XCTAssertEqual(m.tail?.path, b.path)
    }

    // MARK: - #797 (c): showAnyway is per session

    @MainActor
    func testAgentWindowShowAnywayResetsOnASessionSwitch() {
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        let a = AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "a"), dchVersion: "1.29.0", dchState: "idle",
                                      sessionId: nil, transcriptPath: nil)
        m.update(a)
        m.showAnyway = true
        var again = a
        again.dchState = "working"
        m.update(again)
        XCTAssertTrue(m.showAnyway, "the same session keeps it")
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "b"), dchVersion: "1.29.0", dchState: "idle",
                                       sessionId: nil, transcriptPath: nil))
        XCTAssertFalse(m.showAnyway, "another session starts terminal-first again")
    }

    // MARK: - #797 (b): the backward line scan is bounded

    func testAgentWindowLineStartScansBackAtMostMaxLinePlusAPage() throws {
        let url = tempDir().appendingPathComponent("long.jsonl")
        try (Data("{}\n".utf8) + Data(repeating: 0x61, count: 5000)).write(to: url)
        var t = TranscriptTail(path: url.path, pageBytes: 64)
        t.maxLine = 256
        XCTAssertEqual(t.lineStart(before: 5003), 5003 - 320, "the floor stands in for a start further back")
        XCTAssertEqual(t.lineStart(before: 200), 3, "a start inside the bound is found")
        XCTAssertEqual(t.lineStart(before: 3), 3)
        t.maxLine = .max
        XCTAssertEqual(t.lineStart(before: 5003), 3, "no overflow at a huge bound")
    }

    func testAgentWindowAnOversizedTailOpensAsOneTooLargeMarker() throws {
        let url = tempDir().appendingPathComponent("big.jsonl")
        try (line(say("A")) + Data(repeating: 0x61, count: 5000) + Data("\n".utf8)).write(to: url)
        var t = TranscriptTail(path: url.path, pageBytes: 64)
        t.maxLine = 256
        guard case .lines(let live, false) = t.poll() else { return XCTFail() }
        XCTAssertEqual(live.count, 1)
        guard case .oversized = live[0] else { return XCTFail("\(live)") }
        // The rest of the long line is skipped, a few bounded scans per call, never shown again.
        var page: [LineBuffer.Line] = []
        for _ in 0..<5 where page.isEmpty { page = t.previousPage() }
        guard page.count == 1, case .line(let d, _) = page[0] else { return XCTFail("\(page)") }
        guard case .block(.assistant(let c), _) = TranscriptDecoder.decode(line: d).items.first else { return XCTFail() }
        XCTAssertEqual(c.text, "A")
        XCTAssertEqual(t.earliestLoaded, 0)
    }

    // MARK: - #797 (d): the tests QA listed for #786

    func testAgentWindowALineStartingExactlyAtThePageEdgeBelongsToThePage() throws {
        let url = tempDir().appendingPathComponent("edge.jsonl")
        let row = Data((String(repeating: "x", count: 31) + "\n").utf8)   // 32 bytes
        try Data((0..<4).flatMap { _ in row }).write(to: url)
        let t = TranscriptTail(path: url.path, pageBytes: 64)
        XCTAssertEqual(t.pageStart(end: 128), 64, "[64, 128) holds two whole lines")
        XCTAssertEqual(t.pageStart(end: 96), 32)
        XCTAssertEqual(t.pageStart(end: 64), 0)

        var p = TranscriptTail(path: url.path, pageBytes: 64)
        guard case .lines(let live, _) = p.poll() else { return XCTFail() }
        XCTAssertEqual(live.map(\.range), [64..<95, 96..<127])
        XCTAssertEqual(p.previousPage().map(\.range), [0..<31, 32..<63], "every line once, none skipped")
        XCTAssertEqual(p.earliestLoaded, 0)
    }

    func testAgentWindowATrailingPartialLineOnOpenWaitsForItsNewline() throws {
        let url = tempDir().appendingPathComponent("partial.jsonl")
        let whole = (0..<40).map { line(say("m\($0) " + String(repeating: "x", count: 30))) }.reduce(Data(), +)
        let last = line(say("the last one"))
        try (whole + last.prefix(15)).write(to: url)
        var t = TranscriptTail(path: url.path, pageBytes: 512)
        guard case .lines(let first, false) = t.poll() else { return XCTFail() }
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy {
            guard case .line(let d, _) = $0 else { return false }
            return !TranscriptDecoder.decode(line: d).items.contains { if case .block(.failed, _) = $0 { true } else { false } }
        }, "whole lines only, the partial is held back")
        XCTAssertEqual(first.last?.range.upperBound, UInt64(whole.count - 1))
        try append(url, last.dropFirst(15))
        guard case .lines(let rest, false) = t.poll(), rest.count == 1, case .line(let d, _) = rest[0] else { return XCTFail() }
        guard case .block(.assistant(let c), _) = TranscriptDecoder.decode(line: d).items.first else { return XCTFail() }
        XCTAssertEqual(c.text, "the last one")
    }

    @MainActor
    func testAgentWindowAFileWithNoNewlineShowsNothingUntilOne() throws {
        let url = tempDir().appendingPathComponent("nonl.jsonl")
        let one = line(say("only line"))
        try one.dropLast().write(to: url)
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.pageBytes = 16   // smaller than the line: the open path's page search runs too
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        XCTAssertTrue(m.blocks.isEmpty)
        XCTAssertFalse(m.olderAvailable)
        try append(url, Data("\n".utf8))
        m.poll()
        XCTAssertEqual(m.blocks.count, 1)
        XCTAssertFalse(m.blocks.contains(where: \.failed))
    }

    func testAgentWindowAStepInsideAThreadKeepsToolPending() {
        var a = asm([say("start"), toolUse("b1", "Bash", ["command": "sleep 60"], ["isSidechain": true, "agentId": "ag"])])
        if case .thread = a.blocks.last?.body {} else { return XCTFail("\(a.blocks)") }
        XCTAssertTrue(a.toolPending, "a running step inside the last thread (no open Agent call in view)")
        a.add(TranscriptDecoder.decode(line: line(toolResult("b1", "", ["isSidechain": true, "agentId": "ag"]))), source: nil)
        XCTAssertFalse(a.toolPending)
    }

    func testAgentWindowAPageOrphanInsideAThreadPairsWhenItsCallPagesIn() {
        let side: [String: Any] = ["isSidechain": true, "agentId": "ag"]
        var later = asm([toolResult("t1", "out", side), say("after")])
        XCTAssertNotNil(later.orphans["t1"]?.thread, "an orphan inside a thread")
        let page = asm([toolUse("t1", "Bash", ["command": "ls"], side)])
        later.prepend(page)
        XCTAssertTrue(later.orphans.isEmpty)
        XCTAssertEqual(later.blocks.count, 3, "the page's thread, the later thread, the reply")
        guard case .thread = later.blocks[0].body, later.blocks[0].children.count == 1,
              case .bash("ls", _, let out?, _) = later.blocks[0].children[0].body else { return XCTFail("\(later.blocks)") }
        XCTAssertEqual(out.text, "out")
        XCTAssertTrue(later.blocks[1].children.isEmpty, "the orphan card folded into its call")
    }

    func testAgentWindowPrependKeepsOrphansBounded() {
        var later = asm((0..<3).map { toolResult("late\($0)", "x") }, maxPending: 4)
        let page = asm((0..<6).map { toolResult("early\($0)", "x") }, maxPending: 100)
        XCTAssertEqual(page.orphans.count, 6)
        later.prepend(page)
        XCTAssertLessThanOrEqual(later.orphans.count, 4, "paging never grows orphans past the bound")
        XCTAssertEqual(later.blocks.count, 9, "the cards themselves all stay")
    }

    // MARK: - OQ-56 defaults: commands as chips, empty thinking hidden, cwd

    func testAgentWindowSlashCommandsAreChipsAndEmptyThinkingIsHidden() {
        func items(_ e: [String: Any]) -> [DecodedEntry.Item] { TranscriptDecoder.decode(line: line(e)).items }
        let cmd = entry("user", ["message": ["role": "user", "content":
            "<command-message>compact</command-message>\n<command-name>/compact</command-name>\n<command-args>keep it short</command-args>"]])
        guard case .block(.command("/compact", "keep it short"), .specific) = items(cmd).first else { return XCTFail("\(items(cmd))") }
        let bare = entry("user", ["message": ["role": "user", "content": [["type": "text", "text":
            "<command-name>/clear</command-name><command-message>clear</command-message><command-args></command-args>"]]]])
        guard case .block(.command("/clear", nil), _) = items(bare).first else { return XCTFail("\(items(bare))") }
        let prose = entry("user", ["message": ["role": "user", "content": "<command-name>/x</command-name> and more words"]])
        guard case .block(.user, _) = items(prose).first else { return XCTFail("text around the tags stays a message") }

        let thinking = assistant([["type": "thinking", "thinking": "", "signature": "sig"], ["type": "text", "text": "hi"]])
        let got = items(thinking)
        guard got.count == 2, case .hidden = got[0], case .block(.assistant, _) = got[1] else { return XCTFail("\(got)") }
        let real = assistant([["type": "thinking", "thinking": "plan first"]])
        guard case .block(.thinking, _) = items(real).first else { return XCTFail() }
    }

    @MainActor
    func testAgentWindowHeaderCwdComesFromTheNewestEntry() throws {
        let url = tempDir().appendingPathComponent("cwd.jsonl")
        try write(url, [entry("user", ["cwd": "/Users/example/one", "message": ["role": "user", "content": "hi"]]),
                        say("ok", ["cwd": "/Users/example/two"]), say("no cwd"), say("bad", ["cwd": "relative/dir"])])
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        XCTAssertEqual(m.cwd, "/Users/example/two")
        m.stop()
        XCTAssertNil(m.cwd)
    }

    // MARK: - Offscreen renders of the window (never shown)

    static var renderDir: URL? {
        ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// Renders `view` at `size` into a bitmap through an NSHostingView that is never
    /// put in a window, with a `margin` of empty canvas right and below it.
    @MainActor
    func render<V: View>(_ view: V, size: CGSize, dark: Bool, margin: CGFloat = 24) throws -> NSBitmapImageRep {
        let root = ZStack(alignment: .topLeading) {
            Color(nsColor: dark ? .black : .white)
            view.frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width + margin, height: size.height + margin, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: CGSize(width: size.width + margin, height: size.height + margin))
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        h.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.bitmapImageRepForCachingDisplay(in: h.bounds))
        h.cacheDisplay(in: h.bounds, to: rep)
        return rep
    }

    /// Pixels in the margin that differ from the canvas: content drawn past its frame.
    func overflow(_ rep: NSBitmapImageRep, content: CGSize, canvas: CGSize) -> Int {
        let sx = CGFloat(rep.pixelsWide) / canvas.width, sy = CGFloat(rep.pixelsHigh) / canvas.height
        guard let bg = rep.colorAt(x: rep.pixelsWide - 1, y: rep.pixelsHigh - 1)?.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where CGFloat(x) >= content.width * sx + 1 || CGFloat(y) >= content.height * sy + 1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.1 { n += 1 }
            }
        }
        return n
    }

    func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let bg = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) else { return 0 }
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.15 { n += 1 }
            }
        }
        return n
    }

    func save(_ rep: NSBitmapImageRep, _ name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: tempDir("agents-window-renders").appendingPathComponent("\(name).png"))
        if let dir = Self.renderDir { try png.write(to: dir.appendingPathComponent("\(name).png")) }
    }

    static var lightPalette: ThemePalette {
        let json = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions/theme-daylight/theme.json")
        return ThemePalette.load(for: ThemeDescriptor(id: "daylight", title: "Daylight", appearance: .light,
                                                      extensionID: "daylight", jsonPath: json))
    }

    @MainActor
    func demoModel(_ convo: URL) -> (AgentWindowModel, AgentIslandStore) {
        let pr = { (n: Int) in DchSessionMeta.PR(url: "https://github.com/acme/prosper/pull/\(n)", repo: "acme/prosper", num: n, title: "t") }
        let st = store([
            session("prosper", .working, ago: 40, alias: "prosper — agent window", agents: 2,
                    meta: DchSessionMeta(openPRs: [pr(797), pr(801), pr(802)], merged: 3), path: convo.path),
            session("prosper-ios", .blocked, ago: 200, alias: "prosper-ios release with a very long session name that truncates"),
            session("infra", .done, ago: 900),
            session("notes", .idle, ago: 86_400 * 3),
            session("qa-797", .working, ago: 15, agents: 1),
        ], history: [record("old-spike", ago: 7200), record("cdv2", ago: 86_400 * 2)], pattern: "qa-")
        let m = windowModel(st)
        m.setVisible(true)
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "prosper")))
        return (m, st)
    }

    @MainActor
    func testAgentWindowRendersTheWindowAndSidebarOffscreenWithoutClipping() throws {
        let savedScale = ThemeRuntime.scale, savedPalette = ThemeRuntime.palette
        defer { ThemeRuntime.scale = savedScale; ThemeRuntime.palette = savedPalette }
        let convo = Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl")
        let (m, st) = demoModel(convo)
        defer { m.close() }
        XCTAssertGreaterThan(m.transcript.blocks.count, 3)
        st.notices[AgentSessionKey(dir: "/tmp/dch-test", name: "prosper")] = "Attach command copied"
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? savedPalette : Self.lightPalette
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let tag = "\(dark ? "dark" : "light")-\(scale)"
                // The whole window at its minimum and its default size.
                for (label, size) in [("min", CGSize(width: 640 * scale, height: 420 * scale)),
                                      ("default", CGSize(width: 1000 * scale, height: 680 * scale))] {
                    let rep = try render(AgentWindowRootView(model: m, scrolls: false), size: size, dark: dark)
                    try save(rep, "window-\(label)-\(tag)")
                    XCTAssertGreaterThan(ink(rep), 400, "window \(label) \(tag)")
                    XCTAssertEqual(overflow(rep, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)),
                                   0, "nothing drawn past the window (\(label) \(tag))")
                }
                // The sidebar alone, at its fixed width.
                let side = CGSize(width: sz(290), height: 620 * scale)
                let srep = try render(AgentSidebarView(model: m).background(Neon.sidebar), size: side, dark: dark)
                try save(srep, "sidebar-\(tag)")
                XCTAssertEqual(overflow(srep, content: side, canvas: CGSize(width: side.width + 24, height: side.height + 24)), 0,
                               "sidebar \(tag)")
                // The header's fixed parts fit the narrowest detail pane.
                let room = 640 * scale - sz(290) - 1
                let header = AgentSessionHeader(row: try XCTUnwrap(m.selectedRow), session: try XCTUnwrap(m.selectedRow?.session),
                                                cwd: "/Users/example/projects/prosper/app/Sources/ProsperApp/AgentWindow", open: {})
                let hsize = CGSize(width: room, height: 90 * scale)
                let hrep = try render(header, size: hsize, dark: dark)
                try save(hrep, "header-min-\(tag)")
                XCTAssertEqual(overflow(hrep, content: hsize, canvas: CGSize(width: hsize.width + 24, height: hsize.height + 24)),
                               0, "header \(tag)")
                // #1103: the header's button left for its "⋯"; the toggle (icons) stands in as the widest fixed control.
                let shown = try XCTUnwrap(m.selectedRow?.session)
                let chips = NSHostingView(rootView: HStack(spacing: sz(12)) {
                    AgentStateChip(state: .blocked)
                    AgentPaneModeToggle(mode: .terminal, style: .icons, set: { _ in })
                    AgentSessionMenuButton(store: nil, session: shown, ask: { _ in })
                }.fixedSize())
                XCTAssertLessThan(chips.fittingSize.width + sz(32) + sz(60), room,
                                  "state, toggle, \"⋯\", padding and a readable title fit at \(scale)")
            }
        }
        // History selected, the empty states, and the island off.
        ThemeRuntime.palette = savedPalette
        ThemeRuntime.scale = 1.0
        let live = try render(AgentWindowRootView(model: m), size: CGSize(width: 1000, height: 680), dark: true)
        try save(live, "window-live-scrollview")
        XCTAssertGreaterThan(ink(live), 400, "the real (scrolling) view renders too")
        m.select(.history(AgentSessionKey(dir: "/tmp/dch-test", name: "old-spike")))
        let size = CGSize(width: 1000, height: 680)
        let hist = try render(AgentWindowRootView(model: m), size: size, dark: true)
        try save(hist, "window-history-selected")
        XCTAssertGreaterThan(ink(hist), 400)
        let empty = windowModel(store([]))
        empty.setVisible(true)
        defer { empty.close() }
        try save(try render(AgentWindowRootView(model: empty), size: size, dark: true), "window-no-sessions")
        let off = windowModel(nil)
        off.setVisible(true)
        defer { off.close() }
        let offRep = try render(AgentWindowRootView(model: off), size: size, dark: true)
        try save(offRep, "window-island-off")
        XCTAssertGreaterThan(ink(offRep), 100)
    }
}
