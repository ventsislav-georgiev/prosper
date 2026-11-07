import Foundation

// #786 Agent window, spike A: Claude Code transcript decoding (design rules 1-3).
//
// The transcript (~/.claude/projects/<project>/<sessionId>.jsonl) is internal and
// undocumented and drifts every release, so nothing here trusts its shape:
// - one JSONL line at a time; a bad line costs only its own block (rule 1);
// - every field optional, unknown keys ignored, lookups through `TranscriptKeys`
//   aliases (rule 2);
// - three tiers: a specific renderer, else a generic card, else hidden noise. A
//   specific renderer that cannot fill itself returns nil and the generic card
//   takes over; nothing ever yields an empty block (rule 3).
// Read-only: nothing in AgentWindow writes Claude's files (rule 8).

enum TranscriptTier: Int, Sendable { case specific = 1, generic = 2 }

/// Visible-block tiers plus hidden noise, per Claude Code version. `degraded` is the
/// part of `generic` that is drift, not design: an unrecognized entry or content,
/// or a tool whose specific renderer could not read the shape. A generic card for a
/// tool that has no specific renderer is by design and not degraded.
struct TierCounts: Equatable, Sendable {
    var specific = 0, generic = 0, failed = 0, hidden = 0, degraded = 0
    var visible: Int { specific + generic + failed }
    static func + (a: TierCounts, b: TierCounts) -> TierCounts {
        TierCounts(specific: a.specific + b.specific, generic: a.generic + b.generic, failed: a.failed + b.failed,
                   hidden: a.hidden + b.hidden, degraded: a.degraded + b.degraded)
    }
}

/// Text capped for display, with where to re-read the full text (lazy expand).
struct Clip: Equatable, Sendable {
    var text: String
    var total: Int
    /// Byte range of the source line in the transcript; nil when not re-readable.
    var source: Range<UInt64>? = nil
    /// The tool_use id whose result this is, so expand finds the same text again.
    var toolID: String? = nil
    var capped: Bool { total > text.count }

    init(_ s: String, cap: Int, source: Range<UInt64>? = nil, toolID: String? = nil) {
        total = s.count
        text = s.count > cap ? String(s.prefix(cap)) : s
        self.source = source
        self.toolID = toolID
    }
    var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
}

struct DiffLine: Equatable, Sendable {
    enum Kind: Sendable { case context, added, removed }
    var kind: Kind
    var text: String
}

struct CardField: Equatable, Sendable {
    var key: String
    var value: String
}

/// What a block draws. Every case has a header line, so none renders blank.
enum BlockBody: Equatable, Sendable {
    case user(Clip)
    case assistant(Clip)
    case thinking(Clip)
    case image
    case bash(command: String, description: String?, output: Clip?, isError: Bool)
    case diff(tool: String, path: String, lines: [DiffLine], more: Int, isError: Bool)
    case read(path: String, detail: String?)
    case search(tool: String, pattern: String, scope: String?, results: [String], more: Int)
    case compaction(trigger: String?, preTokens: Int?, summary: Clip?)
    case notice(String)
    case thread(agentId: String, title: String)
    /// Tier 2: a tool's name and inputs, or "Unrecognized entry (type)" with raw JSON.
    case card(title: String, fields: [CardField], body: Clip?, raw: Clip?, isError: Bool)
    /// A line that failed to decode at all.
    case failed(reason: String, raw: Clip?)
}

struct TranscriptBlock: Identifiable, Equatable, Sendable {
    let id: Int
    var body: BlockBody
    var tier: TranscriptTier
    var version: String
    var source: Range<UInt64>?
    /// Sidechain (subagent) entries nest under their `.thread` block.
    var children: [TranscriptBlock] = []
    var droppedChildren = 0
    var failed: Bool { if case .failed = body { true } else { false } }
    /// Tier 2 because something was not recognized (see `TierCounts.degraded`).
    var degraded: Bool {
        guard case .card(let title, _, _, let raw, _) = body else { return false }
        return raw != nil || ToolRenderer.specificNames.contains(title)
    }
}

// MARK: - Tolerant field access (rule 2)

enum TranscriptKeys {
    /// Canonical key → every spelling Claude Code has used or plausibly will.
    static let aliases: [String: [String]] = [
        "type": ["type", "entryType", "entry_type"],
        "sessionId": ["sessionId", "session_id"],
        "version": ["version", "claudeVersion", "claude_version"],
        "isSidechain": ["isSidechain", "is_sidechain"],
        "agentId": ["agentId", "agent_id"],
        "isMeta": ["isMeta", "is_meta"],
        "isCompactSummary": ["isCompactSummary", "is_compact_summary"],
        "toolUseResult": ["toolUseResult", "tool_use_result"],
        "tool_use_id": ["tool_use_id", "toolUseId", "tool_use_ID"],
        "is_error": ["is_error", "isError"],
        "subtype": ["subtype", "sub_type"],
        "compactMetadata": ["compactMetadata", "compact_metadata"],
        "preTokens": ["preTokens", "pre_tokens"],
        "file_path": ["file_path", "filePath"],
        "old_string": ["old_string", "oldString"],
        "new_string": ["new_string", "newString"],
        "structuredPatch": ["structuredPatch", "structured_patch"],
        "subagent_type": ["subagent_type", "subagentType"],
        "output_mode": ["output_mode", "outputMode"],
        "numLines": ["numLines", "num_lines"],
        "startLine": ["startLine", "start_line"],
        "totalLines": ["totalLines", "total_lines"],
    ]

    static func get(_ o: [String: Any]?, _ key: String) -> Any? {
        guard let o else { return nil }
        for k in aliases[key] ?? [key] {
            if let v = o[k], !(v is NSNull) { return v }
        }
        return nil
    }
    static func str(_ o: [String: Any]?, _ key: String) -> String? { get(o, key) as? String }
    static func obj(_ o: [String: Any]?, _ key: String) -> [String: Any]? { get(o, key) as? [String: Any] }
    static func arr(_ o: [String: Any]?, _ key: String) -> [Any]? { get(o, key) as? [Any] }
    static func bool(_ o: [String: Any]?, _ key: String) -> Bool { (get(o, key) as? Bool) ?? false }
    /// JSON numbers arrive as NSNumber; a Bool is not an Int here.
    static func int(_ o: [String: Any]?, _ key: String) -> Int? {
        guard let n = get(o, key) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }
}

// MARK: - One line → items

/// The result half of a tool call, kept until its tool_use is found.
struct ToolResultInfo {
    var text: Clip
    var isError: Bool
    /// `toolUseResult`: Claude Code's structured result (dict or string).
    var extra: Any?
}

struct DecodedEntry {
    enum Item {
        case block(BlockBody, TranscriptTier)
        case toolUse(id: String?, name: String, input: [String: Any])
        case toolResult(id: String?, ToolResultInfo)
        case hidden(String)
    }
    var version: String?
    var sessionId: String?
    /// The agentId of a sidechain (subagent) entry; nil on the main thread.
    var sidechain: String?
    var items: [Item] = []
}

enum TranscriptDecoder {
    static let textCap = 6_000
    static let outputCap = 3_000
    static let rawCap = 1_500
    static let fieldCap = 240
    static let diffLineCap = 60
    static let searchCap = 20

    /// Internal bookkeeping types: hidden, counted (tier 3).
    static let noiseTypes: Set<String> = [
        "queue-operation", "atis-latch", "last-prompt", "mode", "permission-mode", "ai-title",
        "custom-title", "agent-name", "api-request", "api-request-blob", "api-request-shape",
        "file-history-snapshot", "file-history-delta", "cost-state", "bridge-session",
        "session-owner", "pr-link", "frame-link", "tools-used", "artifact-autoreact-ledger",
        "artifact-comment-monitor", "summary",
    ]
    static let noiseSystemSubtypes: Set<String> = [
        "turn_duration", "stop_hook_summary", "scheduled_task_fire", "agents_killed",
    ]

    /// One tail line; a line over the size bound becomes a counted "too large" block.
    static func decode(_ l: LineBuffer.Line) -> DecodedEntry {
        switch l {
        case .line(let d, let r): return decode(line: d, source: r)
        case .oversized(let r):
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: r.count), countStyle: .file)
            return DecodedEntry(items: [.block(.failed(reason: "Entry too large to show (\(size))", raw: nil), .generic)])
        }
    }

    static func decode(line: Data, source: Range<UInt64>? = nil, cap: Int = textCap) -> DecodedEntry {
        guard let o = (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) as? [String: Any] else {
            let raw = String(decoding: line.prefix(rawCap * 4), as: UTF8.self)
            return DecodedEntry(items: [.block(.failed(reason: "Unreadable entry", raw: Clip(raw, cap: rawCap)), .generic)])
        }
        typealias K = TranscriptKeys
        var e = DecodedEntry()
        e.version = K.str(o, "version")
        e.sessionId = K.str(o, "sessionId")
        if K.bool(o, "isSidechain") { e.sidechain = K.str(o, "agentId") ?? "subagent" }
        let type = K.str(o, "type") ?? ""
        if noiseTypes.contains(type) {
            e.items = [.hidden(type)]
            return e
        }
        switch type {
        case "user": e.items = user(o, source: source, cap: cap)
        case "assistant": e.items = assistant(o, source: source, cap: cap)
        case "system": e.items = system(o, source: source, cap: cap)
        case "attachment": e.items = attachment(o, cap: cap)
        default: e.items = [unrecognized(type.isEmpty ? "no type" : type, o)]
        }
        return e
    }

    static func unrecognized(_ what: String, _ o: Any) -> DecodedEntry.Item {
        .block(.card(title: "Unrecognized entry (\(what))", fields: [], body: nil,
                     raw: Clip(rawJSON(o), cap: rawCap), isError: false), .generic)
    }

    static func rawJSON(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]) else {
            return String(describing: o)
        }
        return String(decoding: d, as: UTF8.self)
    }

    private static func message(_ o: [String: Any]) -> [String: Any]? { TranscriptKeys.obj(o, "message") }

    private static func user(_ o: [String: Any], source: Range<UInt64>?, cap: Int) -> [DecodedEntry.Item] {
        typealias K = TranscriptKeys
        if K.bool(o, "isMeta") { return [.hidden("user/meta")] }
        let m = message(o)
        let content = K.get(m, "content")
        if K.bool(o, "isCompactSummary") {
            let t = (content as? String) ?? texts(content as? [Any]) ?? ""
            return [.block(.compaction(trigger: nil, preTokens: nil,
                                       summary: t.isEmpty ? nil : Clip(t, cap: cap, source: source)), .specific)]
        }
        if let s = content as? String {
            return s.isBlank ? [.hidden("user/empty")] : [.block(.user(Clip(s, cap: cap, source: source)), .specific)]
        }
        guard let parts = content as? [Any] else { return [unrecognized("user without content", o)] }
        var items: [DecodedEntry.Item] = []
        var text = ""
        for p in parts {
            guard let b = p as? [String: Any] else { continue }
            switch K.str(b, "type") {
            case "text": text += (text.isEmpty ? "" : "\n") + (K.str(b, "text") ?? "")
            case "image": items.append(.block(.image, .specific))
            case "tool_result":
                let id = K.str(b, "tool_use_id")
                let body = resultText(K.get(b, "content")) ?? ""
                items.append(.toolResult(id: id, ToolResultInfo(
                    text: Clip(body, cap: outputCap, source: source, toolID: id),
                    isError: K.bool(b, "is_error"), extra: K.get(o, "toolUseResult"))))
            default: items.append(unrecognized("content \(K.str(b, "type") ?? "?")", b))
            }
        }
        if !text.isBlank { items.insert(.block(.user(Clip(text, cap: cap, source: source)), .specific), at: 0) }
        return items.isEmpty ? [.hidden("user/empty")] : items
    }

    private static func assistant(_ o: [String: Any], source: Range<UInt64>?, cap: Int) -> [DecodedEntry.Item] {
        typealias K = TranscriptKeys
        let content = K.get(message(o), "content")
        if let s = content as? String {
            return s.isBlank ? [.hidden("assistant/empty")] : [.block(.assistant(Clip(s, cap: cap, source: source)), .specific)]
        }
        guard let parts = content as? [Any] else { return [unrecognized("assistant without content", o)] }
        var items: [DecodedEntry.Item] = []
        for p in parts {
            guard let b = p as? [String: Any] else { continue }
            let bt = K.str(b, "type") ?? ""
            switch bt {
            case "text":
                let t = K.str(b, "text") ?? ""
                items.append(t.isBlank ? .hidden("assistant/empty")
                                       : .block(.assistant(Clip(t, cap: cap, source: source)), .specific))
            case "thinking", "redacted_thinking":
                items.append(.block(.thinking(Clip(K.str(b, "thinking") ?? "", cap: cap, source: source)), .specific))
            case "tool_use", "server_tool_use":
                items.append(.toolUse(id: K.str(b, "id"), name: K.str(b, "name") ?? "Tool",
                                      input: K.obj(b, "input") ?? [:]))
            default: items.append(unrecognized("content \(bt.isEmpty ? "?" : bt)", b))
            }
        }
        return items.isEmpty ? [.hidden("assistant/empty")] : items
    }

    private static func system(_ o: [String: Any], source: Range<UInt64>?, cap: Int) -> [DecodedEntry.Item] {
        typealias K = TranscriptKeys
        let sub = K.str(o, "subtype") ?? ""
        if sub == "compact_boundary" {
            let meta = K.obj(o, "compactMetadata")
            return [.block(.compaction(trigger: K.str(meta, "trigger"), preTokens: K.int(meta, "preTokens"),
                                       summary: nil), .specific)]
        }
        if noiseSystemSubtypes.contains(sub) { return [.hidden("system/\(sub)")] }
        if let c = K.str(o, "content").map(stripWrapperTags), !c.isBlank { return [.block(.notice(String(c.prefix(cap))), .specific)] }
        return [unrecognized("system \(sub.isEmpty ? "?" : sub)", o)]
    }

    private static func attachment(_ o: [String: Any], cap: Int) -> [DecodedEntry.Item] {
        let a = TranscriptKeys.obj(o, "attachment")
        // A prompt typed while the agent worked: the one attachment the user wrote.
        if TranscriptKeys.str(a, "type") == "queued_command", let p = TranscriptKeys.str(a, "prompt"), !p.isBlank {
            return [.block(.user(Clip(p, cap: cap)), .specific)]
        }
        return [.hidden("attachment")]
    }

    /// `<local-command-stdout>x</local-command-stdout>` → `x`: Claude Code's wrapper tags
    /// around notices and tool errors. Only for those two; user and model text stay as written.
    static func stripWrapperTags(_ s: String) -> String {
        s.replacingOccurrences(of: "</?[a-z][a-z_-]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// tool_result content: a string, or an array of {type:text,...} parts.
    static func resultText(_ c: Any?) -> String? {
        if let s = c as? String { return s }
        return texts(c as? [Any])
    }

    static func texts(_ parts: [Any]?) -> String? {
        guard let parts else { return nil }
        let t = parts.compactMap { p -> String? in
            guard let b = p as? [String: Any] else { return nil }
            if let s = TranscriptKeys.str(b, "text") { return s }
            return TranscriptKeys.str(b, "type").map { "[\($0)]" }
        }
        return t.isEmpty ? nil : t.joined(separator: "\n")
    }

    /// Lazy expand: the full text `clip` was cut from, re-read from its line. A line can
    /// carry several texts ([thinking, text]): the one the clip is a prefix of is it.
    static func fullText(line: Data, clip: Clip) -> String? {
        let e = decode(line: line, cap: Int.max)
        for item in e.items {
            let full: String
            switch item {
            case .toolResult(let id, let r) where clip.toolID != nil && id == clip.toolID:
                return ToolRenderer.outputText(r) ?? r.text.text
            case .block(.user(let c), _), .block(.assistant(let c), _), .block(.thinking(let c), _),
                 .block(.compaction(_, _, let c?), _):
                full = c.text
            default: continue
            }
            if clip.toolID == nil, full.hasPrefix(clip.text) { return full }
        }
        return nil
    }
}

// MARK: - Tool renderers (tier 1 → tier 2)

enum ToolRenderer {
    /// Tools with a tier-1 renderer; a generic card under one of these names is a fallback.
    static let specificNames: Set<String> = ["Bash", "Edit", "MultiEdit", "Write", "Read", "Grep", "Glob"]

    /// The block for a tool call: the tool's specific renderer, else the generic card.
    static func render(name: String, input: [String: Any], result: ToolResultInfo?) -> (BlockBody, TranscriptTier) {
        if let b = specific(name: name, input: input, result: result) { return (b, .specific) }
        return (generic(name: name, input: input, result: result), .generic)
    }

    /// nil when the shape is not what the renderer knows: the caller falls back a tier.
    static func specific(name: String, input: [String: Any], result: ToolResultInfo?) -> BlockBody? {
        typealias K = TranscriptKeys
        let err = result?.isError ?? false
        switch name {
        case "Bash":
            guard let cmd = K.str(input, "command"), !cmd.isBlank else { return nil }
            let out = result.map { r in outputText(r).map { Clip($0, cap: TranscriptDecoder.outputCap,
                                                                 source: r.text.source, toolID: r.text.toolID) } ?? r.text }
            return .bash(command: cmd, description: K.str(input, "description"), output: out, isError: err)
        case "Edit", "MultiEdit", "Write":
            guard let path = K.str(input, "file_path"), !path.isBlank else { return nil }
            var lines: [DiffLine]
            if let patch = K.arr(result?.extra as? [String: Any], "structuredPatch"), !patch.isEmpty {
                lines = patch.flatMap { h -> [DiffLine] in
                    ((h as? [String: Any]).flatMap { K.arr($0, "lines") } ?? []).compactMap { ($0 as? String).map(diffLine) }
                }
            } else if name == "Write" {
                guard let content = K.str(input, "content") else { return nil }
                lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { DiffLine(kind: .added, text: String($0)) }
            } else {
                guard let old = K.str(input, "old_string"), let new = K.str(input, "new_string") else { return nil }
                lines = old.split(separator: "\n", omittingEmptySubsequences: false).map { DiffLine(kind: .removed, text: String($0)) }
                    + new.split(separator: "\n", omittingEmptySubsequences: false).map { DiffLine(kind: .added, text: String($0)) }
            }
            if lines.count > 1, lines.last?.text.isEmpty == true { lines.removeLast() }
            if err, let r = result { lines.append(DiffLine(kind: .context, text: TranscriptDecoder.stripWrapperTags(r.text.text))) }
            let cap = TranscriptDecoder.diffLineCap
            return .diff(tool: name, path: path, lines: Array(lines.prefix(cap)), more: max(0, lines.count - cap), isError: err)
        case "Read":
            guard let path = K.str(input, "file_path"), !path.isBlank else { return nil }
            let file = K.obj(result?.extra as? [String: Any], "file")
            var detail: String?
            if let start = K.int(file, "startLine"), let n = K.int(file, "numLines"), n > 0,
               case (let last, false) = start.addingReportingOverflow(n - 1) {
                detail = "lines \(start)–\(last)" + (K.int(file, "totalLines").map { " of \($0)" } ?? "")
            } else if let off = K.int(input, "offset") {
                detail = "from line \(off)" + (K.int(input, "limit").map { ", \($0) lines" } ?? "")
            }
            if err { detail = "error: " + String((result?.text.text ?? "").prefix(TranscriptDecoder.fieldCap)) }
            return .read(path: path, detail: detail)
        case "Grep", "Glob":
            guard let pattern = K.str(input, "pattern"), !pattern.isEmpty else { return nil }
            let extra = result?.extra as? [String: Any]
            var rows: [String] = []
            if let files = K.arr(extra, "filenames") as? [String], !files.isEmpty { rows = files }
            else if let c = K.str(extra, "content") ?? result?.text.text { rows = c.split(separator: "\n").map(String.init) }
            let cap = TranscriptDecoder.searchCap
            return .search(tool: name, pattern: pattern, scope: K.str(input, "path") ?? K.str(input, "glob"),
                           results: rows.prefix(cap).map { String($0.prefix(TranscriptDecoder.fieldCap)) },
                           more: max(0, rows.count - cap))
        default:
            return nil
        }
    }

    static func generic(name: String, input: [String: Any], result: ToolResultInfo?) -> BlockBody {
        let fields = input.keys.sorted().prefix(8).map { k in
            CardField(key: k, value: String(fieldText(input[k]).prefix(TranscriptDecoder.fieldCap)))
        }
        let body = result.map { r in outputText(r).map { Clip($0, cap: TranscriptDecoder.outputCap,
                                                             source: r.text.source, toolID: r.text.toolID) } ?? r.text }
        return .card(title: name, fields: Array(fields), body: body, raw: nil, isError: result?.isError ?? false)
    }

    static func fieldText(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        switch v {
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return TranscriptDecoder.rawJSON(v).replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Bash's stdout+stderr from toolUseResult when present; else the tool_result text.
    static func outputText(_ r: ToolResultInfo) -> String? {
        guard let x = r.extra as? [String: Any] else { return nil }
        let out = TranscriptKeys.str(x, "stdout"), errText = TranscriptKeys.str(x, "stderr")
        guard out != nil || errText != nil else { return nil }
        var s = out ?? ""
        if let e = errText, !e.isEmpty { s += (s.isEmpty ? "" : "\n") + e }
        if TranscriptKeys.bool(x, "interrupted") { s += (s.isEmpty ? "" : "\n") + "[interrupted]" }
        return s
    }

    static func diffLine(_ s: String) -> DiffLine {
        switch s.first {
        case "+": DiffLine(kind: .added, text: String(s.dropFirst()))
        case "-": DiffLine(kind: .removed, text: String(s.dropFirst()))
        case " ": DiffLine(kind: .context, text: String(s.dropFirst()))
        default: DiffLine(kind: .context, text: s)
        }
    }
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}
