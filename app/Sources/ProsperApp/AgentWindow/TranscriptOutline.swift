import Foundation

// #904 (#832 X1 step A, spec v2.1 8.1): the transcript's chapters, one per turn of
// `TranscriptVerbosity.turns`, and where a jump to a block lands. Pure: no IO, no state.

enum TranscriptOutline {
    /// Ruling R3 (spec v3.2.6): a title holds at most this many Unicode scalars.
    static let titleCap = 120

    struct Chapter: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case prompt, slash, compaction, partial }
        /// The turn's first block id: stable across polls and paging (ids never change once given).
        let id: Int
        /// 1-based, in transcript order.
        let ordinal: Int
        let title: String
        let kind: Kind
        /// A step of the turn failed: what Focused's summary counts as an error.
        let hasError: Bool
        /// #1354 (X-ray P6, dch xview.c xv_hid): an automatic row: a task notification, a subagent's hand-back, a compaction.
        var auto = false
        /// #1354: the sender when another agent session wrote it ("" unnamed; a hand-back too); nil: not a peer.
        var peer: String? = nil
        /// #1354: the turn's answer (its last reply) and its tools on one line ("Bash 2, Read 1"), for X-ray's Responses.
        var response: String? = nil
        var tools: String? = nil

        enum From: Equatable, Sendable { case own, auto, peer }
        /// dch's row kinds: auto (hidden until shown), peer (dch xv_xs: a peer that is not auto; shown, can be hidden), own.
        var from: From { auto ? .auto : peer != nil ? .peer : .own }
    }

    /// Every turn is a chapter, and so is every further prompt in a turn's lead (v1 OQ-A, no merge: a compaction and
    /// the prompt right after it are two chapters); `turns()` is unchanged. A subagent thread is a block inside its
    /// turn, never a chapter of its own.
    static func chapters(_ blocks: [TranscriptBlock]) -> [Chapter] {
        var out: [Chapter] = []
        for t in TranscriptVerbosity.turns(blocks) {
            for part in prompts(t) {
                // A pasted image leads its prompt; the first other block says what the chapter starts with.
                let lead = part.first { $0.body != .image }
                let (kind, title) = head(lead)
                var origin: PromptOrigin?
                if case .user(let c)? = lead?.body { origin = c.origin }
                // dch README: an auto prompt is titled by its summary, by its title when it has none (a hand-back: its title)
                let shown = origin.flatMap { $0.auto && $0.peer == nil ? $0.summary : nil }.map { Self.title($0, or: title) }
                // a peer's own block is never drawn: its chapter lands on the first drawn block of its part (the answer)
                let first = part.first { !chapterOnly($0.body) } ?? part[part.startIndex]
                var c = Chapter(id: first.id, ordinal: out.count + 1, title: shown ?? title, kind: kind,
                                hasError: part.contains { !TranscriptVerbosity.errorBlocks($0).isEmpty })
                c.auto = kind == .compaction || origin?.auto == true
                c.peer = origin?.peer
                if case .assistant(let a)? = part.last(where: { if case .assistant = $0.body { true } else { false } })?.body {
                    c.response = a.text
                }
                c.tools = tools(part)
                out.append(c)
            }
        }
        return out
    }

    /// The turn cut at each prompt of its lead after the first; images before a prompt go with it. The last part
    /// holds the turn's steps.
    private static func prompts(_ t: [TranscriptBlock]) -> [ArraySlice<TranscriptBlock>] {
        var cuts = [0], seen = false, images: Int?
        for (i, b) in t.enumerated() {
            if b.body == .image { images = images ?? i; continue }
            guard isPrompt(b) else { break }
            if seen { cuts.append(images ?? i) }
            (seen, images) = (true, nil)
        }
        return cuts.indices.map { k in t[cuts[k]..<(k + 1 < cuts.count ? cuts[k + 1] : t.count)] }
    }

    /// #1354: another session's message: the transcript hides it (as at TIP), only the outline and X-ray see it.
    static func chapterOnly(_ b: BlockBody) -> Bool {
        if case .user(let c) = b { c.origin?.peer != nil } else { false }
    }

    /// #1354 (dch README Responses): the part's tool calls by name, in the order first called: "Bash 2, Read 1".
    static func tools(_ part: ArraySlice<TranscriptBlock>) -> String? {
        var names: [String] = [], n: [String: Int] = [:]
        for b in part {
            let name: String?
            switch b.body {
            case .bash: name = "Bash"
            case .read: name = "Read"
            case .thread: name = "Agent"
            case .diff(let tool, _, _, _, _), .search(let tool, _, _, _, _): name = tool
            case .card(let title, _, _, let raw, _): name = raw == nil ? title : nil   // raw: an unrecognized entry
            default: name = nil
            }
            guard let name else { continue }
            if n[name] == nil { names.append(name) }
            n[name, default: 0] += 1
        }
        return names.isEmpty ? nil : names.map { "\($0) \(n[$0, default: 0])" }.joined(separator: ", ")
    }

    private static func isPrompt(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .user, .command, .compaction: true
        default: false
        }
    }

    private static func head(_ b: TranscriptBlock?) -> (Chapter.Kind, String) {
        switch b?.body {
        case .user(let c): return (.prompt, title(c.text, or: "Prompt"))
        case .command(let name, let args): return (.slash, title(args.map { name + " " + $0 } ?? name, or: name))
        case .compaction: return (.compaction, "Conversation compacted")
        default: return (.partial, "Earlier part of a turn")
        }
    }

    /// The first non-blank line, whitespace collapsed, cut to `titleCap` scalars on a character boundary
    /// (a multi-scalar emoji at the edge is left out whole, never split).
    static func title(_ s: String, or blank: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = "", n = 0
        for ch in collapsed {
            n += ch.unicodeScalars.count
            if n > titleCap { break }
            out.append(ch)
        }
        return out.isEmpty ? blank : out
    }

    /// Where a jump to `block` lands at `level`: the turn holding it (the LazyVStack's own child, found even undrawn)
    /// and the row that shows it. nil when no row shows it (not loaded, or hidden at this level).
    static func target(_ block: Int, in blocks: [TranscriptBlock], level: AgentVerbosity) -> (turn: Int, row: String)? {
        guard let row = TranscriptVerbosity.rowID(containing: block, in: blocks, level: level),
              let turn = TranscriptVerbosity.turns(blocks).first(where: { $0.contains { holds($0, block) } }) else { return nil }
        return (turn[0].id, row)
    }

    /// `b` is the block or one of its subagent steps.
    static func holds(_ b: TranscriptBlock, _ id: Int) -> Bool {
        b.id == id || b.children.contains { holds($0, id) }
    }
}
