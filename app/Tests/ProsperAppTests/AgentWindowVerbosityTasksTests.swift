import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #821 round 2 (QA #657): the todo chip from Claude Code's Task tools as well as TodoWrite,
/// paging that matches a whole-file read, pending lines, the Focused step count, notices, image
/// placement and the hidden-entries footer. Synthetic transcripts and fixtures only; offscreen.
extension AgentWindowD1Tests {

    func fixtureLines(_ name: String) throws -> [Data] {
        try Data(contentsOf: Self.corpus.appendingPathComponent(name)).split(separator: UInt8(ascii: "\n"))
            .filter { !$0.isEmpty }.map { Data($0) }
    }

    func assemble(_ lines: ArraySlice<Data>) -> TranscriptAssembler {
        var a = TranscriptAssembler()
        for l in lines { a.add(TranscriptDecoder.decode(line: l), source: nil) }
        return a
    }

    /// A TaskCreate and its result; `n` nil: no toolUseResult, the result text names the id.
    func taskCreate(_ id: String, _ subject: String, n: Int? = nil, _ extra: [String: Any] = [:]) -> [[String: Any]] {
        var structured: [String: Any] = [:]
        if let n { structured = ["task": ["id": String(n), "subject": subject]] }
        let result: [String: Any] = ["toolUseResult": structured]
        return [toolUse(id, "TaskCreate", ["subject": subject, "description": "d", "activeForm": subject + "ing"], extra),
                toolResult(id, "Task #\(n.map(String.init) ?? id) created successfully: \(subject)", result.merging(extra) { $1 })]
    }

    func taskUpdate(_ id: String, _ input: [String: Any], ok: Bool = true) -> [[String: Any]] {
        let task = input["taskId"] as? String ?? "?"
        return [toolUse(id, "TaskUpdate", input),
                toolResult(id, ok ? "Updated task #\(task) status" : "Task not found",
                           ["toolUseResult": ["success": ok, "taskId": task, "updatedFields": ok ? ["status"] : []]])]
    }

    func errorResult(_ id: String, _ text: String) -> [String: Any] {
        entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text,
                                                                 "is_error": true]]]])
    }

    // MARK: F1: Task tools

    func testVerbosityTasksFixtureFeedsTheChipAndHidesTheCards() throws {
        let a = assemble(try fixtureLines("2.1.318/c-tasks.jsonl")[...])
        // #1 done, #2 renamed and in progress, #3 deleted, the subagent's own #4 is not the session's;
        // the refused update and the unknown id change nothing.
        XCTAssertEqual(a.todos?.items, [.init(text: "Add the toggle", status: "completed", id: "1"),
                                        .init(text: "Write the toggle tests", status: "in_progress", id: "2")])
        XCTAssertEqual(a.todos?.label, "Todos 1/2")
        let blocks = a.blocks
        // Default: no Task card but the refused update (it failed); Verbose keeps every card.
        let def = tags(TranscriptVerbosity.project(blocks, level: .default))
        XCTAssertEqual(def.filter { $0.contains("(Task") }, ["line:card(TaskUpdate)"])
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .verbose)).filter { $0.contains("(Task") }.count, 11)
        // Focused: three tool steps (Bash, the refused update, the Agent call), one error.
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .focused)),
                       ["block:user", "summary:3/0/1:1", "block:assistant"])
        let w = assemble(try fixtureLines("2.1.318/d-todowrite.jsonl")[...])
        XCTAssertEqual(w.todos?.label, "Todos 1/3", "the refused rewrite in between changed nothing")
        XCTAssertEqual(w.todos?.items.map(\.text), ["Add the toggle", "Write the tests", "Update the docs"])
        XCTAssertEqual(tags(TranscriptVerbosity.project(w.blocks, level: .default)).filter { $0.contains("TodoWrite") },
                       ["line:card(TodoWrite)"], "only the refused call shows")
    }

    func testVerbosityTodosAfterPagingMatchTheWholeFileAtEverySplit() throws {
        // A third file: the newest list did not parse (drift), after a good one.
        let drift = [
            toolUse("t1", "TodoWrite", ["todos": [["content": "a", "status": "pending"]]]), toolResult("t1", "ok"),
            say("between"),
            toolUse("t2", "TodoWrite", ["todos": "not a list"]), toolResult("t2", "ok"),
        ].map(line)
        for (name, lines) in [("c-tasks", try fixtureLines("2.1.318/c-tasks.jsonl")),
                              ("d-todowrite", try fixtureLines("2.1.318/d-todowrite.jsonl")), ("drift", drift)] {
            let whole = assemble(lines[...]).todos
            if name != "drift" { XCTAssertNotNil(whole, name) }
            var checked = 0
            for i in 0...lines.count {
                for j in i...lines.count {
                    // Newest page first, then the earlier ones, as "Load earlier" does.
                    var a = assemble(lines[j...])
                    a.prepend(assemble(lines[i..<j]))
                    a.prepend(assemble(lines[..<i]))
                    XCTAssertEqual(a.todos, whole, "\(name) split at \(i), \(j)")
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, lines.count)
        }
    }

    func testVerbosityTodosFollowClaudeCodesRules() {
        // A task's id comes from its result: by creation order it would be wrong (a reused id).
        var a = asm(taskCreate("c1", "one", n: 7) + taskCreate("c2", "two", n: 8) + taskUpdate("u1", ["taskId": "8", "status": "in_progress"]))
        XCTAssertEqual(a.todos?.items.map(\.status), ["pending", "in_progress"])
        // The structured result names it even when the text is reworded (drift).
        a = asm([toolUse("c1", "TaskCreate", ["subject": "one"]),
                 toolResult("c1", "Created one", ["toolUseResult": ["task": ["id": "5", "subject": "one"]]])]
                + taskUpdate("u1", ["taskId": "5", "status": "in_progress"]))
        XCTAssertEqual(a.todos?.items, [.init(text: "one", status: "in_progress", id: "5")])
        // Without toolUseResult, the result text names the id.
        a = asm(taskCreate("c1", "one") + taskUpdate("u1", ["taskId": "c1", "status": "in_progress"]))
        XCTAssertEqual(a.todos?.items, [.init(text: "one", status: "in_progress", id: "c1")])
        // A call with no result yet changes nothing; its result applies it.
        a = asm(taskCreate("c1", "one", n: 1) + taskCreate("c2", "two", n: 2) + [toolUse("u1", "TaskUpdate", ["taskId": "1", "status": "completed"])])
        XCTAssertEqual(a.todos?.label, "Todos 0/2")
        a.add(TranscriptDecoder.decode(line: line(toolResult("u1", "Updated task #1 status"))), source: nil)
        XCTAssertEqual(a.todos?.label, "Todos 1/2")
        // Refused (is_error or success false): nothing changes.
        a = asm(taskCreate("c1", "one", n: 1) + taskCreate("c2", "two", n: 2) + taskUpdate("u1", ["taskId": "1", "status": "completed"], ok: false)
                + [toolUse("u2", "TaskUpdate", ["taskId": "2", "status": "completed"]), errorResult("u2", "InputValidationError")])
        XCTAssertEqual(a.todos?.label, "Todos 0/2")
        // Deleted: gone. Renamed: the new subject.
        a = asm(taskCreate("c1", "one", n: 1) + taskCreate("c2", "two", n: 2) + taskUpdate("u1", ["taskId": "1", "status": "deleted"])
                + taskUpdate("u2", ["taskId": "2", "subject": "TWO"]))
        XCTAssertEqual(a.todos?.items.map(\.text), ["TWO"])
        // Every task completed: the list clears, as Claude Code resets it; the next create starts afresh.
        a = asm(taskCreate("c1", "one", n: 1) + taskCreate("c2", "two", n: 2) + taskUpdate("u1", ["taskId": "1", "status": "completed"])
                + taskUpdate("u2", ["taskId": "2", "status": "completed"]))
        XCTAssertNil(a.todos)
        for e in taskCreate("c3", "three", n: 3) { a.add(TranscriptDecoder.decode(line: line(e)), source: nil) }
        XCTAssertEqual(a.todos?.label, "Todos 0/1")
        // A cleared list, then the same id again: one task.
        a = asm(taskCreate("c1", "one", n: 1) + taskUpdate("u1", ["taskId": "1", "status": "completed"]) + taskCreate("c2", "again", n: 1))
        XCTAssertEqual(a.todos?.items, [.init(text: "again", status: "pending", id: "1")])
        // An id still listed comes back (another list: CLAUDE_CODE_TASK_LIST_ID, a team, or a
        // shared list another session emptied): the new task replaces the old, no duplicate.
        a = asm(taskCreate("c1", "one", n: 1) + taskCreate("c2", "two", n: 2) + taskCreate("c3", "three", n: 2))
        XCTAssertEqual(a.todos?.items, [.init(text: "one", status: "pending", id: "1"), .init(text: "three", status: "pending", id: "2")])
        // A subagent's Task calls are its own.
        a = asm(taskCreate("c1", "one", n: 1) + taskCreate("s1", "sub", n: 2, ["isSidechain": true, "agentId": "q"]))
        XCTAssertEqual(a.todos?.items.map(\.text), ["one"])
        // TodoWrite: a refused call keeps the old list; a list with every item completed clears the chip.
        let list = { (s: String) -> [String: Any] in ["todos": [["content": "a", "status": s], ["content": "b", "status": "completed"]]] }
        a = asm([toolUse("t1", "TodoWrite", list("pending")), toolResult("t1", "ok"),
                 toolUse("t2", "TodoWrite", ["todos": [["content": "x", "status": "pending"]]]), errorResult("t2", "InputValidationError")])
        XCTAssertEqual(a.todos?.label, "Todos 1/2")
        for e in [toolUse("t3", "TodoWrite", list("completed")), toolResult("t3", "ok")] {
            a.add(TranscriptDecoder.decode(line: line(e)), source: nil)
        }
        XCTAssertNil(a.todos)
        // TaskList and TaskGet read the list; they never change it, and hide like the others.
        a = asm(taskCreate("c1", "one", n: 1) + [toolUse("l1", "TaskList", [:]),
                                                 toolResult("l1", "#1 [pending] one", ["toolUseResult": ["tasks": []]])])
        XCTAssertEqual(a.todos?.label, "Todos 0/1")
        XCTAssertTrue(a.blocks.allSatisfy { TranscriptVerbosity.defaultRows($0).isEmpty })
    }

    // MARK: INFO-3b: a pending tool reads "running"

    func testVerbosityPendingToolLinesSayRunning() {
        let L = TranscriptVerbosity.lineSummary
        let calls: [(String, String, [String: Any], String)] = [
            ("g", "Grep", ["pattern": "TODO"], "no matches"), ("h", "Glob", ["pattern": "*.swift"], "no matches"),
            ("e", "Edit", ["file_path": "/tmp/project/a.swift", "old_string": "a", "new_string": "b"], "+1 −1"),
            ("w", "Write", ["file_path": "/tmp/project/n.txt", "content": "a\n"], "+1 −0"),
        ]
        for (id, name, input, done) in calls {
            let running = asm([toolUse(id, name, input)])
            XCTAssertEqual(L(running.blocks[0]).status, "running", name)
            XCTAssertTrue(running.toolPending)
            let finished = asm([toolUse(id, name, input), toolResult(id, "", ["toolUseResult": [:]])])
            XCTAssertEqual(L(finished.blocks[0]).status, done, name)
            // Split between the call and its result: the earlier page's call pairs with it.
            var paged = asm([toolResult(id, "", ["toolUseResult": [:]])])
            paged.prepend(asm([toolUse(id, name, input)]))
            XCTAssertEqual(paged.blocks.map { L($0).status }, [done], "\(name) after paging")
        }
        XCTAssertEqual(L(asm([toolUse("x", "WebFetch", ["url": "https://example.com"])]).blocks[0]).status, "running")
        XCTAssertNil(L(asm([toolUse("x", "WebFetch", ["url": "https://example.com"]), toolResult("x", "page")]).blocks[0]).status)
        // A subagent's pending step too.
        let side: [String: Any] = ["isSidechain": true, "agentId": "q"]
        let t = asm([toolUse("a", "Agent", ["description": "Look"]), toolUse("g", "Grep", ["pattern": "x"], side)]).blocks
        XCTAssertEqual(t.last?.children.map { L($0).status }, ["running"])
        // Its result on the next page: paging pairs it and it stops running.
        var paged = asm([toolResult("g", "", side.merging(["toolUseResult": [:]]) { $1 })])
        paged.prepend(asm([toolUse("a", "Agent", ["description": "Look"]), toolUse("g", "Grep", ["pattern": "x"], side)]))
        XCTAssertEqual(paged.blocks.flatMap(\.children).map { L($0).status }, ["no matches"], "a thread step after paging")
        // The pending bound counts open calls: a subagent with more finished steps than the
        // bound still pairs its Agent call with the result.
        let steps = (0..<6).flatMap { [toolUse("s\($0)", "Grep", ["pattern": "x"], side), toolResult("s\($0)", "", side)] }
        let long = asm([toolUse("a", "Agent", ["description": "Look"])] + steps + [toolResult("a", "done", ["toolUseResult": ["agentId": "q"]])],
                       maxPending: 4)
        XCTAssertEqual(long.blocks.count, 2, "the Agent call and its thread: no orphan Tool result card \(long.blocks.map(kind))")
        XCTAssertNil(L(long.blocks[0]).status, "the Agent call finished")
        XCTAssertTrue(long.orphans.isEmpty)
    }

    // MARK: INFO-2: Focused counts tool steps only

    func testVerbosityFocusedCountsToolStepsOnly() {
        let side: [String: Any] = ["isSidechain": true, "agentId": "q"]
        let blocks = asm([
            entry("user", ["message": ["role": "user", "content": "go"]]),
            assistant([["type": "thinking", "thinking": "a"]]), say("Looking."),
            toolUse("b", "Bash", ["command": "ls"]), toolResult("b", "f"),
            toolUse("r", "Read", ["file_path": "/tmp/project/a.swift"]), toolResult("r", "1\tlet a = 1"),
            assistant([["type": "thinking", "thinking": "b"]]), say("Searching."),
            toolUse("g", "Grep", ["pattern": "x"]),
            entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "g", "content": "a.swift"],
                                                                   ["type": "image", "source": ["type": "base64", "data": ""]]]]]),
            toolUse("t", "TodoWrite", ["todos": [["content": "a", "status": "pending"]]]), toolResult("t", "ok"),
            toolUse("a", "Agent", ["description": "Look"]), say("sub", side), toolResult("a", "done", ["toolUseResult": ["agentId": "q"]]),
            entry("system", ["subtype": "informational", "level": "notice", "content": "A notice"]),
            say("Done."),
        ]).blocks
        let rows = TranscriptVerbosity.project(blocks, level: .focused)
        guard rows.count == 3, case .summary(let s, _, _) = rows[1].kind else { return XCTFail("shape \(tags(rows))") }
        XCTAssertEqual(s.steps, 4, "Bash, Read, Grep and the Agent call; not thinking, text, the image, the todo card, the thread or the notice")
        XCTAssertEqual(s.label, "4 steps")
        let talk = asm([entry("user", ["message": ["role": "user", "content": "go"]]), say("Hmm."), say("Done.")]).blocks
        XCTAssertEqual(tags(TranscriptVerbosity.project(talk, level: .focused)), ["block:user", "summary:0/0/0:0", "block:assistant"])
        XCTAssertEqual(TurnSummary(steps: 0, edits: 0, errors: 0, working: false).label, "No tool steps")
    }

    // MARK: INFO-7: a notice is never an error

    func testVerbosityNoticeIsNotAnErrorButAFailedToolIs() {
        let blocks = asm([
            entry("user", ["message": ["role": "user", "content": "go"]]),
            entry("system", ["subtype": "informational", "level": "notice", "content": "No errors found"]),
            entry("system", ["subtype": "informational", "level": "warning", "content": "Error budget: fine"]),
            toolUse("b", "Bash", ["command": "lint"]), errorResult("b", "No errors found"),
            say("Done."),
        ]).blocks
        XCTAssertEqual(blocks.map(TranscriptVerbosity.isError), [false, false, false, true, false])
        XCTAssertFalse(TranscriptVerbosity.lineSummary(blocks[1]).error)
        XCTAssertTrue(TranscriptVerbosity.lineSummary(blocks[3]).error)
        let rows = TranscriptVerbosity.project(blocks, level: .focused)
        guard rows.count == 3, case .summary(let s, _, let errors) = rows[1].kind else { return XCTFail("shape \(tags(rows))") }
        XCTAssertEqual(tags(errors), ["line:bash"], "the failed tool only")
        XCTAssertEqual(s.errors, 1)
    }

    // MARK: INFO-8: images stay with their prompt

    func testVerbosityImagesStayWithTheirPrompt() {
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": ""]]
        let blocks = asm([
            entry("user", ["message": ["role": "user", "content": [["type": "text", "text": "Look at this"], image, image]]]),
            entry("user", ["message": ["role": "user", "content": "and this too"]]),
            toolUse("b", "Bash", ["command": "ls"]), toolResult("b", "f"),
            say("Seen."),
        ]).blocks
        XCTAssertEqual(blocks.map(kind), ["user", "image", "image", "user", "bash", "assistant"])
        // The prompt's images keep it the lead: a second prompt right after them is the same turn.
        XCTAssertEqual(TranscriptVerbosity.turns(blocks).map(\.count), [6])
        // Focused draws them with the prompt, not inside the summary.
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .focused)),
                       ["block:user", "block:image", "block:image", "block:user", "summary:1/0/0:0", "block:assistant"])
    }

    // MARK: INFO-8: the hidden-entries footer is Verbose only

    @MainActor
    func testVerbosityHiddenEntriesFooterShowsInVerboseOnly() throws {
        let pref = "agentWindowVerbosity"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        let convo = [entry("user", ["message": ["role": "user", "content": "go"]]), say("ok")]
        let plain = tempDir().appendingPathComponent("plain.jsonl"), noisy = tempDir().appendingPathComponent("noisy.jsonl")
        try write(plain, convo)
        try write(noisy, convo + [entry("file-history-snapshot", ["snapshot": [:]])])
        var heights: [String: CGFloat] = [:]
        for (name, url) in [("plain", plain), ("noisy", noisy)] {
            let m = windowModel(store([session(name, .idle, ago: 1, path: url.path)]))
            m.setVisible(true)
            defer { m.close() }
            XCTAssertEqual(m.transcript.hiddenCount, name == "noisy" ? 1 : 0)
            for level in AgentVerbosity.allCases {
                let v = AgentTranscriptView(model: m.transcript, scrolls: false, ownsLifecycle: false, level: level)
                heights["\(name) \(level)"] = NSHostingView(rootView: v.frame(width: 560)).fittingSize.height
            }
        }
        XCTAssertEqual(heights["noisy focused"], heights["plain focused"])
        XCTAssertEqual(heights["noisy default"], heights["plain default"])
        XCTAssertGreaterThan(heights["noisy verbose"]!, heights["plain verbose"]!, "the footer line")
    }

    // MARK: INFO-1: the open list is capped and closes on a session switch

    @MainActor
    func testVerbosityTodosListIsCappedAndClosesOnSessionSwitch() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        for scale: CGFloat in [0.7, 1.0] {
            ThemeRuntime.scale = scale
            func height(_ n: Int) -> CGFloat {
                let t = AgentTodos(items: (0..<n).map { .init(text: "task \($0)", status: "pending") })
                return NSHostingView(rootView: AgentTodosList(todos: t).frame(width: 400)).fittingSize.height
            }
            let three = height(3), fifty = height(50)
            XCTAssertGreaterThan(three, sz(30), "a short list keeps its own height")
            XCTAssertLessThan(three, AgentTodosList.maxHeight)
            XCTAssertLessThanOrEqual(fifty, AgentTodosList.maxHeight + 0.5, "50 items scroll inside about 8 rows at \(scale)")
            XCTAssertGreaterThan(fifty, AgentTodosList.maxHeight - sz(16))
        }
        let t = AgentTranscriptModel()
        let a = tempDir().appendingPathComponent("a.jsonl"), b = tempDir().appendingPathComponent("b.jsonl")
        try write(a, [say("a")])
        try write(b, [say("b")])
        func src(_ name: String, _ url: URL) -> AgentTranscriptSource {
            AgentTranscriptSource(key: AgentSessionKey(dir: "/tmp/dch-test", name: name), dchVersion: "1.30.0",
                                  dchState: "idle", sessionId: name, transcriptPath: url.path)
        }
        t.update(src("one", a))
        t.todosOpen = true
        t.update(src("one", a))
        XCTAssertTrue(t.todosOpen, "the same session keeps it open")
        t.update(src("two", b))
        XCTAssertFalse(t.todosOpen, "another session starts closed")
    }

    @MainActor
    func testVerbosityTodosListClosesWhenTheListClears() throws {
        let url = tempDir().appendingPathComponent("todos.jsonl")
        let list = { (s: String) -> [String: Any] in ["todos": [["content": "a", "status": s]]] }
        try write(url, [toolUse("t1", "TodoWrite", list("pending")), toolResult("t1", "ok")])
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        XCTAssertEqual(m.todos?.label, "Todos 0/1")
        m.todosOpen = true
        try append(url, [toolUse("t2", "TodoWrite", list("in_progress")), toolResult("t2", "ok")].map(line).reduce(Data(), +))
        m.poll()
        XCTAssertTrue(m.todosOpen, "a changed list stays open")
        try append(url, [toolUse("t3", "TodoWrite", list("completed")), toolResult("t3", "ok")].map(line).reduce(Data(), +))
        m.poll()
        XCTAssertNil(m.todos)
        XCTAssertFalse(m.todosOpen, "no list, nothing open: the next list starts closed")
    }
}
