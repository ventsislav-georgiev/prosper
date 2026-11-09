import Foundation

// #821: how much of a conversation the Agent Sessions window shows, modeled on Claude Code's
// view modes (focus / default / verbose). A pure projection of the assembler's blocks: no IO,
// no new state, so switching level is instant and tier counts still see every block.
// Drift: it keys only on Prosper's own `BlockBody` cases, never on Claude Code fields. A new
// tool is a generic card upstream and one line here; an unknown entry is one line, not a raw
// card. Default and Focused get quieter when Claude Code drifts; Verbose keeps the raw folds.

/// One level for the whole window, per Mac (`Preferences.agentWindowVerbosity`).
enum AgentVerbosity: String, CaseIterable, Sendable {
    case focused, `default`, verbose

    /// Tolerant: unset or an unknown raw value reads as Default.
    init(raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .default }

    var title: String {
        switch self {
        case .focused: "Focused"
        case .default: "Default"
        case .verbose: "Verbose"
        }
    }

    var icon: String {
        switch self {
        case .focused: "scope"
        case .default: "text.alignleft"
        case .verbose: "list.bullet.rectangle"
        }
    }

    /// ⌥⌘1 / ⌥⌘2 / ⌥⌘3 while the Agent Sessions window is key: the digit row's key codes
    /// (kVK_ANSI_1...3), so the keys sit in the same place on every layout.
    var keyCode: UInt16 {
        switch self {
        case .focused: 18
        case .default: 19
        case .verbose: 20
        }
    }
    var shortcut: String { "⌥⌘\(keyCode - 17)" }
}

/// Default's "Todos 3/7" chip: the session's main-thread todo list. Claude Code 2.1.223+ keeps
/// it with TaskCreate / TaskUpdate (TodoWrite only under CLAUDE_CODE_ENABLE_TASKS=false); both
/// feed this one list.
struct AgentTodos: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var text: String
        var status: String
        /// The task's id (TaskCreate); nil for a TodoWrite item.
        var id: String? = nil
    }
    /// The whole list, in creation order.
    var items: [Item]
    /// Seen in the loaded part of the transcript only (no task store, history not loaded):
    /// the count is unknown, so the chip shows none.
    var partial = false
    /// The cards the chip stands for: hidden at Default and Focused unless they failed.
    static let toolNames: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
    /// The opened list draws at most this many rows; the count is always the whole list's.
    static let maxRows = 50

    var done: Int { items.filter { $0.status == "completed" }.count }
    var label: String { partial ? "Todos" : "Todos \(done)/\(items.count)" }
    /// The opened list: open tasks first (creation order), then completed ones, newest first.
    var rows: [Item] {
        Array((items.filter { $0.status != "completed" } + items.filter { $0.status == "completed" }.reversed()).prefix(Self.maxRows))
    }

    /// The chip for a list: none when it is empty or every item is completed (Claude Code
    /// resets such a list).
    static func chip(_ items: [Item], partial: Bool = false) -> AgentTodos? {
        items.allSatisfy { $0.status == "completed" } ? nil : AgentTodos(items: items, partial: partial)
    }

    /// nil when the input is not a list of todos (drift) or the list is empty: no chip.
    static func parse(_ input: [String: Any]) -> AgentTodos? {
        let items = (TranscriptKeys.arr(input, "todos") ?? []).compactMap { $0 as? [String: Any] }.compactMap { o -> Item? in
            guard let t = TranscriptKeys.str(o, "content") ?? TranscriptKeys.str(o, "activeForm"), !t.isBlank else { return nil }
            return Item(text: String(t.prefix(TranscriptDecoder.fieldCap)), status: TranscriptKeys.str(o, "status") ?? "pending")
        }
        return items.isEmpty ? nil : AgentTodos(items: items)
    }

    // MARK: The list as a fold over the file
    // The assembler keeps every main-thread list call and result as an event, in file order,
    // and an earlier page's events go in front: the list after any paging is the list after
    // reading the whole file, by construction.

    enum Op: Equatable, Sendable {
        /// TodoWrite: the whole list (nil: the input did not parse, drift).
        case write(AgentTodos?)
        case create(subject: String)
        case update(taskId: String, status: String?, subject: String?)
    }

    enum Event: Equatable, Sendable {
        case call(String, Op)
        /// A tool result: `ok` false when it failed; `taskId` is the id a TaskCreate got.
        case result(String, ok: Bool, taskId: String?)
    }

    /// nil for every tool that does not change the list (TaskList and TaskGet only read it).
    static func op(name: String, input: [String: Any]) -> Op? {
        typealias K = TranscriptKeys
        let subject = K.str(input, "subject").flatMap { $0.isBlank ? nil : String($0.prefix(TranscriptDecoder.fieldCap)) }
        switch name {
        case "TodoWrite": return .write(parse(input))
        case "TaskCreate": return subject.map { .create(subject: $0) }
        case "TaskUpdate": return K.str(input, "taskId").map { .update(taskId: $0, status: K.str(input, "status"), subject: subject) }
        default: return nil
        }
    }

    /// Claude Code answers a TaskCreate with "Task #N created successfully: …" and
    /// `toolUseResult.task.id`; a TaskUpdate it refused carries `success: false`.
    static func result(_ id: String, _ r: ToolResultInfo) -> Event {
        typealias K = TranscriptKeys
        let x = r.extra as? [String: Any]
        var taskId = K.str(K.obj(x, "task"), "id")
        if taskId == nil, r.text.text.hasPrefix("Task #"),
           let n = r.text.text.dropFirst(6).split(separator: " ", maxSplits: 1).first { taskId = String(n) }
        return .result(id, ok: !r.isError && (K.get(x, "success") as? Bool) != false, taskId: taskId)
    }

    /// What the fold knows after the events.
    struct Folded: Equatable, Sendable {
        var items: [Item] = []
        /// A TodoWrite set the list whole at some point: from there it is exact. A clear does not
        /// count: the fold clears when every LOADED task is completed, which on a partial page is
        /// not Claude Code's clear (QA #657 r3 F1).
        var known = false
        /// The last call that changed the list was a TodoWrite (Claude Code's task store does
        /// not hold that list).
        var write = false
        /// Refused calls (is_error or success false): their cards stay visible.
        var refused: Set<String> = []
        /// Updates to a task the events never created: the fold could not place them.
        var unplaced: Set<String> = []
    }

    /// The list after `events`, the way Claude Code keeps it: a call counts once its result is
    /// in and did not fail (a rejected TodoWrite keeps the old list), and a list whose every
    /// item is completed is cleared.
    /// ponytail: Claude Code clears completed tasks after 5 s, not at once; a TaskCreate within
    /// those 5 s keeps the old ones there and starts afresh here. Timestamps if that matters.
    static func fold(_ events: [Event]) -> Folded {
        var calls: [String: Op] = [:], f = Folded()
        for e in events {
            switch e {
            case .call(let id, let op): calls[id] = op
            case .result(let id, let ok, let taskId):
                guard let op = calls.removeValue(forKey: id) else { continue }
                guard ok else { f.refused.insert(id); continue }
                f.write = false
                switch op {
                case .write(let list):
                    f.items = list?.items ?? []
                    (f.known, f.write) = (true, true)
                case .create(let subject):
                    // No id in the result (drift): shown, but no update can reach it.
                    let tid = taskId ?? "use:" + id
                    f.items.removeAll { $0.id == tid }
                    f.items.append(Item(text: subject, status: "pending", id: tid))
                case .update(let tid, let status, let subject):
                    guard let i = f.items.firstIndex(where: { $0.id == tid }) else { f.unplaced.insert(id); continue }
                    if status == "deleted" { f.items.remove(at: i); break }
                    if let status { f.items[i].status = status }
                    if let subject { f.items[i].text = subject }
                }
                if !f.items.isEmpty, f.items.allSatisfy({ $0.status == "completed" }) { f.items = [] }
            }
        }
        return f
    }
}

/// #821 (QA #657 F2): Claude Code's own task list, `<config>/tasks/<list id>/<id>.json`, read
/// only. A session's list id is its session id unless CLAUDE_CODE_TASK_LIST_ID is set or the
/// session is in a team (Prosper cannot see either; those lists fall back to the transcript).
enum AgentTaskStore {
    /// `<config>/projects/<slug>/<file>.jsonl` → `<config>/tasks/<session id>`; nil for a
    /// transcript somewhere else.
    static func directory(_ s: AgentTranscriptSource) -> URL? {
        guard let path = s.transcriptPath, let id = s.sessionId, !id.isEmpty else { return nil }
        let projects = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        guard projects.lastPathComponent == "projects" else { return nil }
        // Claude Code's own sanitizing of a list id.
        let name = String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" ? Character($0) : "-" })
        return projects.deletingLastPathComponent().appendingPathComponent("tasks").appendingPathComponent(name)
    }

    static let maxFiles = 1_000
    static let maxFileBytes = 64 << 10

    /// The tasks by id; nil when there is no directory, it cannot be read, or none of its task
    /// files parse (drift): the transcript is the fallback. A bad file is skipped. Past
    /// `maxFiles` the lowest ids are read.
    static func read(_ dir: URL, limit: Int = maxFiles) -> [AgentTodos.Item]? {
        typealias K = TranscriptKeys
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let files = names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .map { (Int($0.dropLast(5)) ?? .max, $0) }.sorted { $0 < $1 }.prefix(limit).map(\.1)
        var items: [(Int, AgentTodos.Item)] = [], parsed = 0
        for f in files {
            guard let d = regularFile(dir.appendingPathComponent(f).path, max: maxFileBytes),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let id = K.str(o, "id"), let subject = K.str(o, "subject"),
                  let status = K.str(o, "status"), ["pending", "in_progress", "completed"].contains(status) else { continue }
            parsed += 1
            // TaskList leaves these out too.
            if K.get(K.obj(o, "metadata"), "_internal") as? Bool == true { continue }
            items.append((Int(id) ?? .max, AgentTodos.Item(text: String(subject.prefix(TranscriptDecoder.fieldCap)), status: status, id: id)))
        }
        if parsed == 0 && !files.isEmpty { return nil }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A regular file's bytes, at most `max`; nil for anything else. Never follows a symlink, and
    /// a FIFO opens without blocking (then fails the regular-file check): the io queue never waits.
    static func regularFile(_ path: String, max: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= max,
              let d = try? h.read(upToCount: max + 1), d.count <= max else { return nil }
        return d
    }
}

struct TurnSummary: Equatable, Sendable {
    var steps: Int
    var edits: Int
    var errors: Int
    /// The last turn still waits on a tool.
    var working: Bool

    var label: String {
        if working { return steps > 0 ? "Working · " + plural(steps, "step") : "Working" }
        return ([steps > 0 ? plural(steps, "step") : "No tool steps"] + (edits > 0 ? [plural(edits, "edit")] : []) + (errors > 0 ? [plural(errors, "error")] : []))
            .joined(separator: " · ")
    }
}

/// What the window draws for a level: a block as today, a block as one line, a subagent
/// thread cut to its tail, or a Focused turn's steps folded into a summary.
struct TranscriptRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case block(TranscriptBlock)
        /// One line; a click opens today's card in place.
        case line(TranscriptBlock)
        /// Header, "N earlier steps not shown", then `children` (one line each).
        case thread(TranscriptBlock, earlier: Int, children: [TranscriptRow])
        /// Folded: the summary and the turn's `errors`; open: `children`, the steps at Default.
        case summary(TurnSummary, children: [TranscriptRow], errors: [TranscriptRow])
    }
    let id: String
    let kind: Kind
}

enum TranscriptVerbosity {
    /// Claude Code's default keeps a subagent's last 3 progress messages (`bP=3`).
    static let threadTail = 3

    static func project(_ blocks: [TranscriptBlock], level: AgentVerbosity, working: Bool = false) -> [TranscriptRow] {
        if level == .verbose { return blocks.map(full) }
        let turns = turns(blocks)
        return turns.indices.flatMap { i -> [TranscriptRow] in
            let t = turns[i]
            let rows = level == .focused ? focused(t, working: working && i == turns.count - 1) : t.flatMap(defaultRows)
            // A turn never renders empty: its last block as one line (a thinking-only page, drift).
            return rows.isEmpty ? [line(t[t.count - 1])] : rows
        }
    }

    /// A turn starts at a prompt (the user, a slash command, a compaction) after a step.
    static func turns(_ blocks: [TranscriptBlock]) -> [[TranscriptBlock]] {
        var out: [[TranscriptBlock]] = [], cur: [TranscriptBlock] = [], lead = true
        for b in blocks {
            if isPrompt(b) && !lead { out.append(cur); cur = []; lead = true }
            if !isPrompt(b) && !isImage(b) { lead = false }
            cur.append(b)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Default

    static func defaultRows(_ b: TranscriptBlock) -> [TranscriptRow] {
        if hiddenAtDefault(b) { return [] }
        switch b.body {
        case .user, .assistant, .command, .image, .read, .compaction:
            return [full(b)]
        case .thread:
            let kids = b.children.filter { !hiddenAtDefault($0) }
            let tail = kids.suffix(threadTail)
            // An error before the tail stays visible: errors show at every level.
            let shown = kids.dropLast(threadTail).filter(isError) + tail
            return [TranscriptRow(id: "b\(b.id)", kind: .thread(b, earlier: b.droppedChildren + b.children.count - shown.count,
                                                                 children: shown.map(line)))]
        default:
            return [line(b)]
        }
    }

    /// Thinking, and the todo/task cards (the header's chip stands for them), unless they failed
    /// or the chip could not place them (`listShown`).
    /// An unknown entry's card (the only one with `raw`) is titled "Unrecognized entry (…)".
    static func hiddenAtDefault(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .thinking: true
        case .card(let title, _, _, _, let err): AgentTodos.toolNames.contains(title) && !err && !b.listShown
        default: false
        }
    }

    // MARK: Focused

    /// The prompt, one summary line for the steps (with their errors), the final reply.
    static func focused(_ t: [TranscriptBlock], working: Bool) -> [TranscriptRow] {
        let lead = t.prefix { isPrompt($0) || isImage($0) }
        let rest = t.dropFirst(lead.count)
        let final = rest.last { if case .assistant = $0.body { true } else { false } }
        let steps = rest.filter { $0.id != final?.id }
        var rows = lead.map(full)
        let children = steps.flatMap(defaultRows)
        if !children.isEmpty || working {
            let errors = steps.flatMap(errorBlocks)
            let edits = steps.filter { if case .diff = $0.body { true } else { false } }.count
            let s = TurnSummary(steps: steps.filter(isToolStep).count, edits: edits, errors: errors.count, working: working)
            rows.append(TranscriptRow(id: "s\(t[0].id)", kind: .summary(s, children: children, errors: errors.map(line))))
        }
        if let final { rows.append(full(final)) }
        return rows
    }

    /// A tool call the summary counts: not thinking, text, an image, a notice, an unknown entry
    /// or a card the chip stands for. A subagent counts once, as its Agent call.
    static func isToolStep(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .bash, .diff, .read, .search: true
        case .card(_, _, _, let raw, _): raw == nil && !hiddenAtDefault(b)
        default: false
        }
    }

    // MARK: Errors and lines

    /// What Claude Code flagged (`is_error`), never a guess from the text: a notice is never an
    /// error ("No errors found"); Claude Code writes its system errors (`api_error`) without text.
    static func isError(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .bash(_, _, _, let e), .diff(_, _, _, _, let e), .card(_, _, _, _, let e): e
        case .read(_, let d): d?.hasPrefix("error:") == true
        default: false
        }
    }

    /// The block and its subagent steps that failed.
    static func errorBlocks(_ b: TranscriptBlock) -> [TranscriptBlock] {
        (isError(b) ? [b] : []) + b.children.flatMap(errorBlocks)
    }

    struct Line: Equatable {
        var icon: String
        var title: String
        var detail: String?
        var status: String?
        var error = false
        /// Unknown entries open nothing (no raw JSON outside Verbose).
        var expandable = true
    }

    static func lineSummary(_ b: TranscriptBlock) -> Line {
        var l: Line
        switch b.body {
        case .user(let c): l = Line(icon: "person", title: "You", detail: firstLine(c.text))
        case .assistant(let c): l = Line(icon: "text.bubble", title: "Claude", detail: firstLine(c.text))
        case .thinking: l = Line(icon: "brain", title: "Thinking")
        case .image: l = Line(icon: "photo", title: "Image")
        case .command(let n, let a): l = Line(icon: "chevron.right.square", title: n, detail: a)
        case .bash(let cmd, _, let out, let e):
            let status = out.map { o in e ? "error" : o.text.isEmpty ? "no output" : plural(o.lineCount, "line") } ?? "running"
            l = Line(icon: "terminal", title: "$", detail: firstLine(cmd), status: status)
        case .diff(let tool, let path, let lines, _, let e):
            let add = lines.filter { $0.kind == .added }.count, del = lines.filter { $0.kind == .removed }.count
            l = Line(icon: tool == "Write" ? "doc.badge.plus" : "pencil", title: tool, detail: path,
                     status: e ? "error" : "+\(add) −\(del)")
        case .read(let path, let d): l = Line(icon: "doc.text", title: "Read", detail: path, status: d)
        case .search(let tool, let pattern, _, let results, let more):
            l = Line(icon: "magnifyingglass", title: tool, detail: pattern,
                     status: results.isEmpty ? "no matches" : plural(results.count + more, "result"))
        case .compaction: l = Line(icon: "rectangle.compress.vertical", title: "Conversation compacted")
        case .notice(let t): l = Line(icon: "info.circle", title: "Notice", detail: firstLine(t))
        case .thread(_, let title): l = Line(icon: "person.2", title: "Subagent", detail: title == "Subagent" ? nil : title)
        case .card(let title, let fields, _, let raw, let e):
            l = Line(icon: raw == nil ? "wrench.and.screwdriver" : "questionmark.square.dashed", title: title,
                     detail: raw == nil ? fields.first.map { firstLine($0.value) } : nil, status: e ? "error" : nil,
                     expandable: raw == nil)
        case .failed(let reason, _): l = Line(icon: "exclamationmark.triangle", title: reason, expandable: false)
        }
        l.error = isError(b)
        // Still waiting on its result: no "no matches" or "+a −d" as if it were done.
        if b.pending { l.status = "running" }
        return l
    }

    private static func full(_ b: TranscriptBlock) -> TranscriptRow { TranscriptRow(id: "b\(b.id)", kind: .block(b)) }
    private static func line(_ b: TranscriptBlock) -> TranscriptRow { TranscriptRow(id: "b\(b.id)", kind: .line(b)) }
    private static func isPrompt(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .user, .command, .compaction: true
        default: false
        }
    }
    private static func isImage(_ b: TranscriptBlock) -> Bool { b.body == .image }

    static func firstLine(_ s: String) -> String {
        String((s.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? "").prefix(200))
            .trimmingCharacters(in: .whitespaces)
    }
}

func plural(_ n: Int, _ word: String, _ many: String? = nil) -> String {
    "\(n) \(n == 1 ? word : many ?? word + "s")"
}
