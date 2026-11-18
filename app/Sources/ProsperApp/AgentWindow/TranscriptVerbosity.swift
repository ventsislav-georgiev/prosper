import Foundation

// #821: how much of a conversation the Agent Sessions window shows, modeled on Claude Code's
// view modes (focus / default / verbose). A pure projection of the assembler's blocks: no IO,
// no new state, so switching level is instant and tier counts still see every block.
// Drift: it keys only on Prosper's own `BlockBody` cases, never on Claude Code fields. A new
// tool is a generic card upstream and one line here; an unknown entry is one line, not a raw
// card. Default and Focused get quieter when Claude Code drifts; Verbose keeps the raw folds.

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
    /// Seen in the loaded part of the transcript only (no task store, history not loaded; the list shows AgentTodosList.partialNote):
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
/// session is in a team. Neither is in the transcript lines or dch's row (#1270: only sessionId,
/// transcript_path), so those lists fall back to the transcript.
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

enum TranscriptVerbosity {
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

    private static func isPrompt(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .user, .command, .compaction: true
        default: false
        }
    }
    private static func isImage(_ b: TranscriptBlock) -> Bool { b.body == .image }
}
