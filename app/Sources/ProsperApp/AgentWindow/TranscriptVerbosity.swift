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

/// The newest main-thread TodoWrite list: Default's "Todos 3/7" chip.
struct AgentTodos: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var text: String
        var status: String
    }
    var items: [Item]
    static let toolName = "TodoWrite"

    var done: Int { items.filter { $0.status == "completed" }.count }
    var label: String { "Todos \(done)/\(items.count)" }

    /// nil when the input is not a list of todos (drift) or the list is empty: no chip.
    static func parse(_ input: [String: Any]) -> AgentTodos? {
        let items = (TranscriptKeys.arr(input, "todos") ?? []).compactMap { $0 as? [String: Any] }.compactMap { o -> Item? in
            guard let t = TranscriptKeys.str(o, "content") ?? TranscriptKeys.str(o, "activeForm"), !t.isBlank else { return nil }
            return Item(text: String(t.prefix(TranscriptDecoder.fieldCap)), status: TranscriptKeys.str(o, "status") ?? "pending")
        }
        return items.isEmpty ? nil : AgentTodos(items: Array(items.prefix(50)))
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
        return ([plural(steps, "step")] + (edits > 0 ? [plural(edits, "edit")] : []) + (errors > 0 ? [plural(errors, "error")] : []))
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

    /// Thinking, and the TodoWrite card (the header's chip stands for it), unless it failed.
    static func hiddenAtDefault(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .thinking: true
        case .card(let title, _, _, _, let err): title == AgentTodos.toolName && !err
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
            let s = TurnSummary(steps: steps.count, edits: edits, errors: errors.count, working: working)
            rows.append(TranscriptRow(id: "s\(t[0].id)", kind: .summary(s, children: children, errors: errors.map(line))))
        }
        if let final { rows.append(full(final)) }
        return rows
    }

    // MARK: Errors and lines

    static func isError(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .bash(_, _, _, let e), .diff(_, _, _, _, let e), .card(_, _, _, _, let e): e
        case .read(_, let d): d?.hasPrefix("error:") == true
        case .notice(let t): t.localizedCaseInsensitiveContains("error")
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
