import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #821: the Agent Sessions window's verbosity levels (Focused / Default / Verbose). Pure
/// projection tests on synthetic transcripts (fake paths only), the fixture corpus through all
/// three levels, the preference, the keys, no IO on a switch, and offscreen header renders.
/// Offscreen only: no window is shown and no event is posted.
extension AgentWindowD1Tests {

    /// The design's turn: user, thinking, assistant, Bash, Edit (error), Grep, Agent + a thread
    /// of 5 steps, TodoWrite, an unrecognized entry, the final assistant text.
    func verbosityTurn(threadSteps: Int = 5, errorStep: Int? = nil) -> [TranscriptBlock] {
        let side: [String: Any] = ["isSidechain": true, "agentId": "ag-1"]
        var es: [[String: Any]] = [
            entry("user", ["message": ["role": "user", "content": "Fix the build in /tmp/project"]]),
            assistant([["type": "thinking", "thinking": "Let me look."]]),
            say("Checking the build first."),
            toolUse("b1", "Bash", ["command": "make\nmake test", "description": "Build"]), toolResult("b1", "ok\ndone"),
            toolUse("e1", "Edit", ["file_path": "/tmp/project/a.swift", "old_string": "a", "new_string": "b"]),
            entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "e1",
                                                                     "content": "File has not been read yet", "is_error": true]]]]),
            toolUse("g1", "Grep", ["pattern": "TODO"]), toolResult("g1", "/tmp/project/a.swift"),
            toolUse("a1", "Agent", ["description": "Explore the tests", "prompt": "Look around"]),
        ]
        for i in 0..<threadSteps {
            if i == errorStep {
                es.append(toolUse("s\(i)", "Bash", ["command": "false"], side))
                es.append(entry("user", side.merging(["message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "s\(i)", "content": "exit 1", "is_error": true]]]]) { $1 }))
            } else {
                es.append(say("step \(i)", side))
            }
        }
        es += [
            toolResult("a1", "Found it", ["toolUseResult": ["agentId": "ag-1"]]),
            toolUse("t1", "TodoWrite", ["todos": [["content": "Fix", "status": "completed"], ["content": "Test", "status": "pending"]]]),
            toolResult("t1", "ok"),
            entry("mystery-entry", ["payload": 1]),
            say("Done: the build passes."),
        ]
        return asm(es).blocks
    }

    /// One short tag per row: "block:user", "line:bash", "thread:2:3", "summary:4/1/1:1".
    func tags(_ rows: [TranscriptRow]) -> [String] {
        rows.map { r in
            switch r.kind {
            case .block(let b): "block:" + kind(b)
            case .line(let b): "line:" + kind(b)
            case .thread(_, let earlier, let kids): "thread:\(earlier):\(kids.count)"
            case .summary(let s, _, let errors): "summary:\(s.steps)/\(s.edits)/\(s.errors):\(errors.count)"
            }
        }
    }

    func kind(_ b: TranscriptBlock) -> String {
        switch b.body {
        case .user: "user"
        case .assistant: "assistant"
        case .thinking: "thinking"
        case .image: "image"
        case .bash: "bash"
        case .diff: "diff"
        case .read: "read"
        case .search: "search"
        case .compaction: "compaction"
        case .notice: "notice"
        case .thread: "thread"
        case .command: "command"
        case .card(let t, _, _, let raw, _): raw == nil ? "card(\(t))" : "unknown"
        case .failed: "failed"
        }
    }

    /// Every block a row draws (Verbose draws a block with all its children).
    func visible(_ rows: [TranscriptRow], level: AgentVerbosity) -> [Int] {
        rows.flatMap { r -> [Int] in
            switch r.kind {
            case .block(let b): [b.id] + (level == .verbose ? b.children.map(\.id) : [])
            case .line(let b): [b.id]
            case .thread(let b, _, let kids): [b.id] + visible(kids, level: level)
            case .summary(_, _, let errors): visible(errors, level: level)
            }
        }
    }

    func testVerbosityProjectsTheDesignTurnPerLevel() {
        let blocks = verbosityTurn()
        XCTAssertEqual(blocks.map(kind), ["user", "thinking", "assistant", "bash", "diff", "search", "card(Agent)", "thread",
                                          "card(TodoWrite)", "unknown", "assistant"])
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .verbose)), blocks.map { "block:" + kind($0) })
        // Default: no thinking, tools as one line, the thread's last 3 steps, no TodoWrite card.
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .default)),
                       ["block:user", "block:assistant", "line:bash", "line:diff", "line:search", "line:card(Agent)",
                        "thread:2:3", "line:unknown", "block:assistant"])
        // Focused: the prompt, one summary (4 tool steps, 1 edit, 1 error) carrying the error, the final reply.
        let focused = TranscriptVerbosity.project(blocks, level: .focused)
        XCTAssertEqual(tags(focused), ["block:user", "summary:4/1/1:1", "block:assistant"])
        guard focused.count == 3, case .summary(let s, let kids, let errors) = focused[1].kind, case .block(let final) = focused[2].kind else {
            return XCTFail("shape")
        }
        XCTAssertEqual(s.label, "4 steps · 1 edit · 1 error")
        XCTAssertEqual(tags(errors), ["line:diff"])
        XCTAssertEqual(final.body, .assistant(Clip("Done: the build passes.", cap: 100)), "the final text, not the one between steps")
        XCTAssertEqual(tags(kids), Array(tags(TranscriptVerbosity.project(blocks, level: .default)).dropFirst().dropLast()),
                       "opening the summary shows the steps at Default")
    }

    func testVerbosityThreadKeepsItsLastThreeStepsAndEveryError() {
        func thread(_ blocks: [TranscriptBlock]) -> (earlier: Int, kids: [TranscriptRow])? {
            for r in TranscriptVerbosity.project(blocks, level: .default) {
                if case .thread(_, let e, let k) = r.kind { return (e, k) }
            }
            return nil
        }
        XCTAssertEqual(thread(verbosityTurn(threadSteps: 3))?.earlier, 0)
        XCTAssertEqual(thread(verbosityTurn(threadSteps: 3))?.kids.count, 3)
        let t = thread(verbosityTurn(threadSteps: 8))
        XCTAssertEqual(t?.earlier, 5)
        XCTAssertEqual(t.map { tags($0.kids) }, ["line:assistant", "line:assistant", "line:assistant"], "children are one line each")
        // A failed step before the tail stays visible, in order, ahead of the tail.
        let e = thread(verbosityTurn(threadSteps: 6, errorStep: 0))
        XCTAssertEqual(e.map { tags($0.kids) }, ["line:bash", "line:assistant", "line:assistant", "line:assistant"])
        XCTAssertEqual(e?.earlier, 2)
        // Focused lifts it into the summary's error lines too.
        let f = TranscriptVerbosity.project(verbosityTurn(threadSteps: 6, errorStep: 0), level: .focused)
        XCTAssertEqual(tags(f)[1], "summary:4/1/2:2")
    }

    func testVerbosityOneLineRowsSayWhatHappened() {
        let b = verbosityTurn()
        let L = TranscriptVerbosity.lineSummary
        XCTAssertEqual(L(b[3]), .init(icon: "terminal", title: "$", detail: "make", status: "2 lines"))
        XCTAssertEqual(L(b[4]), .init(icon: "pencil", title: "Edit", detail: "/tmp/project/a.swift", status: "error", error: true))
        XCTAssertEqual(L(b[5]), .init(icon: "magnifyingglass", title: "Grep", detail: "TODO", status: "1 result"))
        XCTAssertEqual(L(b[6]), .init(icon: "wrench.and.screwdriver", title: "Agent", detail: "Explore the tests"))
        // Unknown input is quiet: its type only, no raw JSON, nothing to open.
        XCTAssertEqual(L(b[9]), .init(icon: "questionmark.square.dashed", title: "Unrecognized entry (mystery-entry)",
                                      expandable: false))
        let failed = asm([]).blocks + [TranscriptBlock(id: 1, body: .failed(reason: "Unreadable entry", raw: Clip("{", cap: 9)),
                                                       tier: .generic, version: "x", source: nil)]
        XCTAssertEqual(L(failed[0]).expandable, false)
        XCTAssertFalse(L(failed[0]).error, "a line that did not decode is drift, not an error")
        let running = asm([toolUse("r", "Bash", ["command": "sleep 9"])]).blocks[0]
        XCTAssertEqual(L(running).status, "running")
        let diff = asm([toolUse("w", "Write", ["file_path": "/tmp/project/n.txt", "content": "a\nb\n"]), toolResult("w", "")]).blocks[0]
        XCTAssertEqual(L(diff).status, "+2 −0")
    }

    func testVerbosityUnknownEntriesGetQuieterAndNeverEmptyATurn() {
        // A future Claude Code: renamed tools and unknown entries only, no assistant text.
        let blocks = asm([
            entry("user", ["message": ["role": "user", "content": "go"]]),
            toolUse("x1", "ShellV2", ["cmd": "make", "nested": ["a": 1]]), toolResult("x1", "ok"),
            entry("brand-new-kind", ["blob": ["k": "v"]]),
            entry("brand-new-kind", ["blob": ["k": "w"]]),
        ]).blocks
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .default)),
                       ["block:user", "line:card(ShellV2)", "line:unknown", "line:unknown"])
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .focused)), ["block:user", "summary:1/0/0:0"])
        XCTAssertEqual(tags(TranscriptVerbosity.project(blocks, level: .verbose)),
                       ["block:user", "block:card(ShellV2)", "block:unknown", "block:unknown"], "Verbose keeps the raw cards")
        // A page that starts mid-turn with thinking only still shows something at every level.
        let thinking = asm([assistant([["type": "thinking", "thinking": "hmm"]])]).blocks
        for level in AgentVerbosity.allCases {
            XCTAssertEqual(TranscriptVerbosity.project(thinking, level: level).count, 1, "\(level)")
        }
        XCTAssertEqual(TranscriptVerbosity.project([], level: .focused), [])
    }

    func testVerbosityLiveTurnSaysWorking() {
        let a = asm([entry("user", ["message": ["role": "user", "content": "go"]]), say("On it."),
                     toolUse("b", "Bash", ["command": "make"])])
        XCTAssertTrue(a.toolPending)
        let rows = TranscriptVerbosity.project(a.blocks, level: .focused, working: a.toolPending)
        XCTAssertEqual(tags(rows), ["block:user", "summary:1/0/0:0", "block:assistant"], "the newest text so far")
        guard rows.count == 3, case .summary(let s, _, _) = rows[1].kind else { return XCTFail("shape") }
        XCTAssertEqual(s.label, "Working · 1 step")
        // Only the last turn is the live one.
        let two = asm([entry("user", ["message": ["role": "user", "content": "a"]]), toolUse("x", "Bash", ["command": "ls"]),
                       toolResult("x", "f"), entry("user", ["message": ["role": "user", "content": "b"]])]).blocks
        XCTAssertEqual(tags(TranscriptVerbosity.project(two, level: .focused, working: true)),
                       ["block:user", "summary:1/0/0:0", "block:user", "summary:0/0/0:0"])
    }

    func testVerbosityFixtureInvariantsAtEveryLevel() throws {
        let files = AgentWindowTests.fixtures()
        XCTAssertGreaterThanOrEqual(files.count, 7)
        var sawThinking = false
        for f in files {
            var a = TranscriptAssembler()
            for l in try Data(contentsOf: f).split(separator: UInt8(ascii: "\n")) where !l.isEmpty {
                a.add(TranscriptDecoder.decode(line: Data(l)), source: nil)
            }
            let blocks = a.blocks, name = f.lastPathComponent
            let errors = Set(blocks.flatMap(TranscriptVerbosity.errorBlocks).map(\.id))
            var counts: [AgentVerbosity: Int] = [:]
            for level in AgentVerbosity.allCases {
                let rows = TranscriptVerbosity.project(blocks, level: level)
                counts[level] = rows.count
                for t in TranscriptVerbosity.turns(blocks) {
                    XCTAssertFalse(TranscriptVerbosity.project(t, level: level).isEmpty, "\(name) \(level): a turn is never empty")
                }
                XCTAssertTrue(errors.isSubset(of: Set(visible(rows, level: level))), "\(name) \(level): every error shows")
                if level != .verbose {
                    XCTAssertFalse(tags(rows).contains { $0.hasPrefix("block:") && ["bash", "diff", "search", "thinking", "unknown",
                                                                                     "failed", "notice"].contains($0.dropFirst(6)) },
                                   "\(name) \(level): no full tool card, thinking or raw card")
                    XCTAssertFalse(tags(rows).contains { $0.hasPrefix("block:card(") }, "\(name) \(level)")
                }
            }
            sawThinking = sawThinking || blocks.contains { if case .thinking = $0.body { true } else { false } }
            XCTAssertLessThanOrEqual(counts[.default]!, counts[.verbose]!, name)
            XCTAssertLessThanOrEqual(counts[.focused]!, counts[.default]!, name)
            if blocks.contains(where: { if case .thinking = $0.body { true } else { false } }) {
                XCTAssertLessThan(counts[.default]!, counts[.verbose]!, "\(name): Default shows less than today")
            }
        }
        XCTAssertTrue(sawThinking)
    }

    // MARK: Todos (Q4)

    func testVerbosityTodosChipIsTheNewestMainThreadList() {
        let list: (Int) -> [String: Any] = { done in
            ["todos": (0..<7).map { ["content": "task \($0)", "status": $0 < done ? "completed" : $0 == done ? "in_progress" : "pending"] }]
        }
        let side: [String: Any] = ["isSidechain": true, "agentId": "q"]
        var a = asm([toolUse("t1", "TodoWrite", list(1)), toolResult("t1", "ok"),
                     toolUse("t2", "TodoWrite", list(3)), toolResult("t2", "ok"),
                     toolUse("t3", "TodoWrite", ["todos": [["content": "sub", "status": "pending"]]], side), toolResult("t3", "ok", side)])
        XCTAssertEqual(a.todos?.label, "Todos 3/7", "the newest main-thread list; a subagent's is not the session's")
        XCTAssertEqual(a.todos?.items.count, 7)
        // Drift: a list that does not parse clears the chip rather than show an older list.
        for e in [toolUse("t4", "TodoWrite", ["todos": "not a list"]), toolResult("t4", "ok")] {
            a.add(TranscriptDecoder.decode(line: line(e)), source: nil)
        }
        XCTAssertNil(a.todos)
        XCTAssertNil(AgentTodos.parse(["todos": []]))
        XCTAssertNil(AgentTodos.parse(["items": [["content": "x"]]]))
        XCTAssertEqual(AgentTodos.parse(["todos": [["activeForm": "Doing", "status": 7], ["content": " "], "junk"]])?.label, "Todos 0/1")
        // Paging: an earlier page's list counts only while this page has none.
        var later = asm([say("hi")])
        later.prepend(asm([toolUse("t1", "TodoWrite", list(2)), toolResult("t1", "ok")]))
        XCTAssertEqual(later.todos?.label, "Todos 2/7")
        var newer = asm([toolUse("t9", "TodoWrite", list(5)), toolResult("t9", "ok")])
        newer.prepend(asm([toolUse("t1", "TodoWrite", list(2)), toolResult("t1", "ok")]))
        XCTAssertEqual(newer.todos?.label, "Todos 5/7")
        // QA #657 INFO-8: the newest list did not parse; an older page loaded later never brings
        // the older list back.
        var drift = asm([toolUse("t9", "TodoWrite", ["todos": "not a list"]), toolResult("t9", "ok")])
        drift.prepend(asm([toolUse("t1", "TodoWrite", list(2)), toolResult("t1", "ok")]))
        XCTAssertNil(drift.todos)
    }

    @MainActor
    func testVerbosityTodosChipShowsAtDefaultOnly() throws {
        let st = store([session("one", .working, ago: 1)])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        let row = try XCTUnwrap(m.selectedRow), s = try XCTUnwrap(row.session)
        let todos = AgentTodos(items: [.init(text: "a", status: "completed"), .init(text: "b", status: "pending")])
        for (level, shown) in [(AgentVerbosity.focused, false), (.default, true), (.verbose, false)] {
            let h = AgentSessionHeader(row: row, session: s, cwd: "/tmp/project", open: {}, level: .constant(level), todos: todos)
            XCTAssertEqual(h.shownTodos != nil, shown, "\(level)")
        }
        // The TodoWrite card itself: hidden at Default and Focused unless it failed, a card in Verbose.
        let ok = asm([toolUse("t", "TodoWrite", ["todos": [["content": "a", "status": "pending"]]]), toolResult("t", "ok")]).blocks
        let bad = asm([toolUse("t", "TodoWrite", ["todos": 3]),
                       entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t",
                                                                                "content": "bad input", "is_error": true]]]])]).blocks
        XCTAssertTrue(TranscriptVerbosity.defaultRows(ok[0]).isEmpty)
        XCTAssertEqual(tags(TranscriptVerbosity.defaultRows(bad[0])), ["line:card(TodoWrite)"])
        XCTAssertEqual(tags(TranscriptVerbosity.project(ok, level: .verbose)), ["block:card(TodoWrite)"])
    }

    // MARK: The level: default, persistence, keys, no IO

    @MainActor
    func testVerbosityDefaultsToDefaultAndPersistsPerMac() {
        let pref = "agentWindowVerbosity"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.removeObject(forKey: pref)
        XCTAssertEqual(AgentVerbosity(raw: nil), .default)
        XCTAssertEqual(AgentVerbosity(raw: "chatty"), .default, "an unknown value reads as Default")
        XCTAssertEqual(Preferences.agentWindowVerbosity, .default)
        XCTAssertEqual(windowModel(nil).verbosity, .default)
        XCTAssertEqual(AgentTranscriptView(model: AgentTranscriptModel()).level, .default)
        for v in AgentVerbosity.allCases { XCTAssertEqual(AgentVerbosity(raw: v.rawValue), v) }
        let m = windowModel(nil)
        m.verbosity = .focused
        XCTAssertEqual(Preferences.defaults.string(forKey: pref), "focused", "written through Preferences.defaults")
        XCTAssertEqual(windowModel(nil).verbosity, .focused, "a new window starts at the saved level")
        Preferences.defaults.set("louder", forKey: pref)
        XCTAssertEqual(windowModel(nil).verbosity, .default)
        XCTAssertFalse(SyncedKeys.isSynced(pref), "per Mac, not synced")
    }

    @MainActor
    func testVerbosityKeysOptionCommandOneTwoThree() {
        let pref = "agentWindowVerbosity"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        let m = windowModel(nil)
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)!
        }
        for (code, v) in [(UInt16(18), AgentVerbosity.focused), (20, .verbose), (19, .default)] {
            XCTAssertTrue(win.performKeyEquivalent(with: key(code, [.command, .option])))
            XCTAssertEqual(m.verbosity, v)
        }
        for flags: NSEvent.ModifierFlags in [[.command], [.option], [.command, .option, .shift], [.command, .option, .control]] {
            XCTAssertNil(AgentsNSWindow.verbosity(for: key(18, flags)), "\(flags)")
        }
        XCTAssertNil(AgentsNSWindow.verbosity(for: key(21, [.command, .option])), "⌥⌘4 is not a level")
        XCTAssertEqual(AgentVerbosity.allCases.map(\.shortcut), ["⌥⌘1", "⌥⌘2", "⌥⌘3"])
    }

    @MainActor
    func testVerbositySwitchDoesNoIO() throws {
        let pref = "agentWindowVerbosity"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        let url = tempDir().appendingPathComponent("v.jsonl")
        try write(url, [entry("user", ["message": ["role": "user", "content": "go"]]), say("ok")])
        let m = windowModel(store([session("one", .idle, ago: 1, path: url.path)]))
        m.setVisible(true)
        defer { m.close() }
        let t = m.transcript
        XCTAssertEqual(t.blocks.count, 2)
        var jobs = 0
        t.offMain = { jobs += 1; $0() }
        let before = (t.generation, t.tail?.offset, t.watchArms, t.busy)
        for v in [AgentVerbosity.focused, .verbose, .default, .focused] { m.verbosity = v }
        XCTAssertEqual(jobs, 0, "no read, decode or page on a switch")
        XCTAssertEqual(t.generation, before.0)
        XCTAssertEqual(t.tail?.offset, before.1)
        XCTAssertEqual(t.watchArms, before.2)
        XCTAssertEqual(t.busy, before.3)
        XCTAssertEqual(t.blocks.count, 2)
    }

    // MARK: Offscreen header audit (#821 A.7, A.8 item 5)

    @MainActor
    func testVerbosityHeaderFitsAtEveryScaleOffscreen() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        let st = store([session("prosper", .working, ago: 40, alias: "prosper — agent window")])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        let row = try XCTUnwrap(m.selectedRow), s = try XCTUnwrap(row.session)
        let todos = AgentTodos(items: (0..<7).map { .init(text: "task \($0)", status: $0 < 3 ? "completed" : "pending") })
        // QA #657 INFO-1: an open list of 60 (it scrolls past about 8 rows), seen in part (round 2c: no count, a note).
        let long = AgentTodos(items: (0..<60).map { .init(text: "task \($0) with a longer description", status: $0 < 3 ? "completed" : "pending") },
                              partial: true)
        var audit: [String] = [], heights: [String] = []
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            func width<V: View>(_ v: V) -> CGFloat { NSHostingView(rootView: v.fixedSize()).fittingSize.width }
            let labels = width(AgentVerbosityPicker(level: .constant(.default), style: .labels))
            let icons = width(AgentVerbosityPicker(level: .constant(.default), style: .icons))
            let menu = width(AgentVerbosityPicker(level: .constant(.default), style: .menu))
            // #1120 (QA 845 INFO-5): the line's controls since #1103: the picker, the mode switch and the "⋯" (sz(18)).
            let toggle = width(AgentPaneModeToggle(mode: .terminal, style: .icons, set: { _ in }))
            let toggleMenu = width(AgentPaneModeToggle(mode: .terminal, style: .menu, set: { _ in }))
            let chip = width(AgentStateChip(state: .working)), todo = width(AgentTodosChip(todos: todos, open: .constant(false)))
            for w: CGFloat in [640, 800, 1000] {
                let room = w * scale - sz(290) - 1
                // Padding, a readable title (60 pt), the state chip, the slot's Spacer, the picker, the mode switch and
                // the "⋯", each after a sz(8) spacing: the menu variant fits at every width, the icon variant from
                // 800 × scale up.
                let narrow = sz(32) + sz(60) + chip + sz(8) + icons + toggle + sz(18) + sz(8) * 5
                let narrowMenu = narrow - icons - toggle + menu + toggleMenu
                XCTAssertLessThanOrEqual(narrowMenu, room, "the menu variant fits with the mode switch at \(scale) × \(w)")
                if w >= 800 { XCTAssertLessThanOrEqual(narrow, room, "the icon variant fits with the mode switch at \(scale) × \(w)") }
                for level in AgentVerbosity.allCases {
                  for open in [false, true] {
                    let h = AgentSessionHeader(row: row, session: s, cwd: "/Users/user/project/app/Sources", open: {},
                                               level: .constant(level), todos: open ? long : todos, todosOpen: .constant(open))
                    // The header's own height at this width (the window stacks it at its natural height).
                    let fit = NSHostingView(rootView: h.frame(width: room)).fittingSize.height
                    heights.append(String(format: "%@%@ %.0f×%.2f h=%.1f", level.rawValue, open ? " open" : "", w, scale, fit))
                    let listRoom = open && level == .default ? AgentTodosList.maxHeight + sz(8) : 0
                    XCTAssertLessThanOrEqual(fit, 100 * scale + listRoom, "header \(level) open \(open) at \(scale) × \(w) stays about as tall as before")
                    if open && level == .default { XCTAssertGreaterThan(fit, 100 * scale, "the open list shows") }
                    let size = CGSize(width: room, height: fit)
                    let rep = try render(h, size: size, dark: true)
                    try save(rep, "verbosity-header-\(level)\(open ? "-open" : "")-\(scale)-\(Int(w))")
                    XCTAssertGreaterThan(ink(rep), 50)
                    XCTAssertEqual(overflow(rep, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)),
                                   0, "header \(level) open \(open) at \(scale) × \(w)")
                  }
                }
                audit.append(String(format: "scale %.2f width %4.0f room %6.1f | labels %5.1f icons %5.1f menu %4.1f | switch %5.1f "
                                    + "switch menu %4.1f chip %4.1f todos %4.1f | need: icon variant %6.1f, menu variant %6.1f", scale, w * scale,
                                    room, labels, icons, menu, toggle, toggleMenu, chip, todo, narrow, narrowMenu))
            }
            XCTAssertLessThan(icons, labels)
            XCTAssertLessThan(menu, icons)
        }
        print("verbosity-header-audit\n" + audit.joined(separator: "\n") + "\n" + heights.joined(separator: "\n"))
    }

    @MainActor
    func testVerbosityRendersTheConversationAtEachLevelOffscreen() throws {
        let pref = "agentWindowVerbosity"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        let url = tempDir().appendingPathComponent("r.jsonl")
        let side: [String: Any] = ["isSidechain": true, "agentId": "ag-1"]
        try write(url, [
            entry("user", ["message": ["role": "user", "content": "Fix the build in /tmp/project"]]),
            assistant([["type": "thinking", "thinking": "Let me look."]]),
            toolUse("b1", "Bash", ["command": "make"]), toolResult("b1", "ok\ndone"),
            toolUse("a1", "Agent", ["description": "Explore"]),
            say("one", side), say("two", side), say("three", side), say("four", side),
            toolResult("a1", "Found it", ["toolUseResult": ["agentId": "ag-1"]]),
            say("Done: the build passes."),
        ])
        let m = windowModel(store([session("one", .idle, ago: 1, path: url.path)]))
        m.setVisible(true)
        defer { m.close() }
        var heights: [AgentVerbosity: CGFloat] = [:]
        for level in AgentVerbosity.allCases {
            m.verbosity = level
            let v = AgentTranscriptView(model: m.transcript, scrolls: false, ownsLifecycle: false, level: level)
            let h = NSHostingView(rootView: v.frame(width: 560).environment(\.colorScheme, .dark))
            heights[level] = h.fittingSize.height
            let size = CGSize(width: 560, height: h.fittingSize.height)
            let rep = try render(v, size: size, dark: true)
            try save(rep, "verbosity-conversation-\(level)")
            XCTAssertGreaterThan(ink(rep), 200, "\(level)")
            // The whole window at this level too (the prompt panel and input box stay at every level).
            try save(try render(AgentWindowRootView(model: m, scrolls: false), size: CGSize(width: 1000, height: 680), dark: true),
                     "verbosity-window-\(level)")
        }
        XCTAssertLessThan(heights[.focused]!, heights[.default]!)
        XCTAssertLessThan(heights[.default]!, heights[.verbose]!)
    }
}
